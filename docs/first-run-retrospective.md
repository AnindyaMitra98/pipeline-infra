# End-to-end pipeline: first real run, 23–24 September 2026

A record of taking this project from reviewed code to a working pipeline on
real AWS and back to zero. It covers what was done at each step, what broke,
why, and what the fixes teach.

The runbook, [`usage.md`](usage.md), is the procedure. This file is the story
of the first time it was actually followed.

---

## 1. Outcome at a glance

| | |
|---|---|
| **Result** | All 12 runbook steps completed. Dev, staging and prod all ran the same image (`7bba6991`), each Healthy behind its own NLB, then everything was torn down cleanly |
| **Flow proved** | GitHub push → GitLab pull mirror → CI (test, build, Trivy gate, push) → ECR over OIDC → Argo Image Updater commits the tag to git → ArgoCD syncs dev → PR promotes to staging → PR plus manual sync releases prod |
| **AWS cost** | About **$0.70**, for roughly 3 hours at ~$0.25/hr |
| **Resources** | 70 created, 70 destroyed, 0 left in state, no orphaned billables |
| **Issues found** | 4 in the pre-apply review, 1 while testing against a local k3s cluster, 7 during the real run, and 1 operator slip. All fixed and pushed except the slip, which needed no code change |
| **Left running** | The S3 state bucket and DynamoDB lock table (pennies a month), the GitLab project, and the GitHub repos |

---

## 2. Environment

| Item | Value |
|---|---|
| Machine | Windows 10, PowerShell 5.1 (the user) and Git Bash (the assistant) |
| AWS | Account `180285183661`, `us-east-1`, IAM user credentials |
| GitHub | `AnindyaMitra98/pipeline-app`, `pipeline-gitops`, `pipeline-infra` (all public) |
| GitLab | Project `tcs-group8000839/pipeline-app` (id 86820004), group on the Ultimate trial, **which ends 2026-10-23** |
| Tools | Terraform 1.8.4, Helm 4.2.3, AWS CLI 2.15, Docker 29.7, kubectl 1.30 at first, later 1.36.1 |
| Cluster | EKS 1.35, 2 × t3.medium SPOT, AL2023 |

### Pinned platform charts

| Chart | Version | App |
|---|---|---|
| `argo/argo-cd` | 10.9.2 | Argo CD v3.5.3 |
| `external-secrets/external-secrets` | 2.11.0 | ESO v2.11.0 |
| `argo/argocd-image-updater` | 1.3.1 | Image Updater v1.3.0 |
| `prometheus-community/kube-prometheus-stack` | 91.5.0 | Operator v0.94.0 |

---

## 3. Phase 0: pre-apply review (free, nothing created)

Before spending anything, everything was checked against the **current**
upstream charts rather than the ones the code had been written against. The
runbook installed charts without a `--version`, and upstream had moved on.

**Checks run:** `terraform validate`, `terraform plan` (70 to add), `npm test`
(8/8), `helm lint` and `helm template` for all three environments, and a pull
and inspection of each current chart.

### Blockers found

| # | Problem | Would have shown up as | Fix |
|---|---|---|---|
| R1 | **Image Updater 1.x is a CRD-driven controller.** It ignores Application annotations unless an `ImageUpdater` resource selects the app | Dev silently never updating; no error anywhere | Added `gitops/apps/root/dev-image-updater.yaml`: `namePattern: sample-app-dev` (exact, not a glob) with `useAnnotations: true` |
| R2 | **ESO 0.17+ stopped serving `external-secrets.io/v1beta1`** | `no matches for kind ClusterSecretStore` in Step 6.4 | Moved both ESO manifests to `v1` |
| R3 | **GitLab pull mirroring needs Premium or Ultimate.** The runbook said the Free tier was fine | Stuck in Step 3 | Used the 30-day Ultimate trial. It attaches to a **group**, so the project had to live inside it |
| R4 | `server.insecure=true` makes ArgoCD speak plain HTTP, but the docs said `https://localhost:8081` | A UI that won't load | Docs now say `http://` |

Smaller items: the Image Updater git keys had been renamed (`gitCommitUser` →
`config.git.user`), the runbook wrongly said the IAM trust checks branch
*protection*, the node `ami_type` was set explicitly to AL2023, and all four
chart versions were pinned in both `usage.md` and `install.ps1`.

### Local verification in throwaway k3s

To validate the manifests server-side for free, the assistant ran k3s as one
Docker container, installed all four pinned charts with the runbook's exact
commands, applied every manifest, then deleted the container.

| # | Found | Fix |
|---|---|---|
| K1 | Image Updater's Deployment is now named **`argocd-image-updater-controller`**, which broke three `kubectl logs` commands. The ServiceAccount name, which the IRSA trust depends on, was unchanged | Updated `usage.md` |

**Learning:** a single-container k3s cluster is a cheap and strong check.
Server-side dry-runs against real CRDs catch API-version and schema drift that
`helm template` cannot.

---

## 4. The run, step by step

### Step 1: repositories
These already existed from an earlier session: three separate public repos,
deliberately not a monorepo, so CI, ArgoCD and Terraform each have their own
blast radius.

### Step 2: Terraform state backend
```powershell
cd infra\bootstrap-state
terraform init
terraform plan          # 6 to add
terraform apply
terraform output -raw backend_config
```
This created `pipeline-portfolio-tfstate-qnuaq0` (versioned, AES256,
public access blocked) and `pipeline-portfolio-tf-locks` (pay-per-request).
The output was pasted into `infra/envs/cluster/backend.tf`, followed by
`terraform init -migrate-state`. A locked `plan` confirmed the lock is taken
and released.

> Back up `bootstrap-state\terraform.tfstate`. It is local and gitignored, and
> it is the only record Terraform has of the bucket and table.

### Step 3: GitLab mirror
1. New project → *Run CI/CD for external repository* → *Repository by URL* →
   `https://github.com/AnindyaMitra98/pipeline-app.git`, **inside the trial
   group**.
2. Checked that the mirror was set to Pull with *Trigger pipelines for mirror
   updates* on, and that `main` was protected.

The group's **URL path** (`tcs-group8000839`) differs from its display name
(`TCS-group`). The IAM trust policy needs the path, which the API shows at
`https://gitlab.com/api/v4/groups?min_access_level=10`.

### Step 4: provision AWS
`terraform.tfvars` (gitignored):
```hcl
gitlab_allowed_subjects = ["project_path:tcs-group8000839/pipeline-app:ref_type:branch:ref:main"]
public_access_cidrs     = ["<YOUR_IP>/32"]   # your own IP; curl -s ifconfig.me
```
```powershell
cd infra\envs\cluster
terraform apply         # 70 to add, ~15-20 min
```
Afterwards the cluster was ACTIVE on 1.35, the API was restricted to one IP,
two SPOT nodes were running in us-east-1a/b, and the three secrets were
created.

### Step 5: connect
```powershell
aws eks update-kubeconfig --region us-east-1 --name pipeline-portfolio
kubectl get nodes       # 2 Ready, v1.35.8
```
**Tooling issue:** `kubectl` reported v1.30, too old for a 1.35 cluster. An
old `C:\Users\anind\kubectl.exe` sat in a folder on the **system** PATH,
which Windows searches before the user PATH where winget installs. Renaming it
to `kubectl-1.30.0.exe.bak` let Docker Desktop's v1.36.1 take over.

### Step 6: platform
| Sub-step | Verified by |
|---|---|
| 6.2 ArgoCD | 7 pods Running. `dex` restarted twice on first boot (`server.secretkey is missing`), a harmless startup race |
| 6.3 repo secret | Label `argocd.argoproj.io/secret-type=repository`, URL matching `repoURL`. The token was checked for format only and never printed |
| 6.4 ESO | Role annotation present, `AWS_ROLE_ARN` and token file injected, ClusterSecretStore **Valid**. A throwaway ExternalSecret synced `pipeline-app/dev` in 4 seconds, which proved the IAM policy, not just authentication |
| 6.5 Image Updater | IRSA annotation present, the CRD installed, and **the ECR login script run by hand inside the pod** |
| 6.6 Prometheus | 6 pods, **0 PVCs**. Node capacity 23/34 pod slots |
| 6.7 UIs | ArgoCD at `http://localhost:8081`, Grafana at `http://localhost:3000` |

### Step 7: CI variables
`AWS_ROLE_ARN`, `AWS_REGION` and `ECR_REPOSITORY`, all visible, unprotected,
and **not credentials**. Checked through the GitLab API for exact values.

### Step 8: GitOps placeholders
Deciding to publish the account ID in the public gitops repo was the user's
call. AWS account IDs are identifiers, not credentials. Before committing, the
registry string was checked to be **identical** in the `image-list`
annotation, `values.yaml` and the Terraform output, because Image Updater
matches it character for character and fails silently on a mismatch.

### Step 9: register the Applications
`kubectl apply -f apps/root/` created 3 Applications and 1 ImageUpdater.
Expected state: dev and staging `ImagePullBackOff` (`REPLACE_ME`), prod
OutOfSync/Missing. Image Updater logged `no tags found ... errors=0`, which
meant it had authenticated to ECR and the registry was simply empty.

### Step 10: first deploy
It took four pipeline runs and two chart fixes to get green (section 5).
The final chain:
```
push job:  "Arn": "arn:aws:sts::180285183661:assumed-role/pipeline-portfolio-gitlab-ci/gitlab-86820004-2876537907"
           Login Succeeded
           Pushed .../sample-app:7bba6991
updater:   images_updated=1 errors=0  ->  commit 19380d2 by argocd-image-updater
argocd:    sample-app-dev  Synced / Healthy
app:       {"sha":"7bba6991","environment":"dev","ready":true}
```
While this was happening, **AWS reclaimed both SPOT nodes**. EKS replaced them,
and every platform pod rescheduled without intervention.

### Step 11: promotion
- **Staging:** the tag was copied into `values-staging.yaml` and merged
  (`538dba1`). ArgoCD auto-synced, and staging served the same SHA and colour
  as dev: the tested build, promoted, not rebuilt.
- **Prod:** PR #1, merged as `92c5804`, then a **manual Sync** in the ArgoCD
  UI. 3 replicas, Healthy.

At the end, nodes were at 30/34 pod slots, with one node at 16/17.

### Step 12: teardown
```powershell
kubectl delete applications --all -n argocd          # stop selfHeal recreating things
kubectl delete svc --all -n sample-app-dev           # ...and staging, prod
# poll until NLBs = 0, classic = 0, ELB ENIs = 0  (started at 3 / 0 / 6)
terraform destroy                                     # 70 to destroy
```
The Applications had no finalizers, so deleting them left the Services
behind. That's why the Services are deleted explicitly. A post-destroy sweep
found no leftover EKS, EC2, EBS, ENIs, NAT, EIPs, NLBs, ECR, secrets, IAM
roles, OIDC providers or log groups.

---

## 5. Issues found during the real run

Each of these passed every static check: validate, plan, lint, template, unit
tests and the local k3s run. They only appeared against real AWS, GitLab and
EKS.

| # | Step | Symptom | Root cause | Fix | Commit |
|---|---|---|---|---|---|
| **1** | 6.0 | Every captured variable came back empty | Windows PowerShell does not expand a variable inside a bare argument that starts with `-`, so `terraform -chdir=$TF` passed the literal text `$TF` | Quote the whole argument: `terraform "-chdir=$TF"`. Print values as `[$VAR]` so an empty one is obvious | infra `2c67739` |
| — | 6.4 | Consequence of #1: ESO installed with a **blank** IAM role and the ClusterSecretStore failed `region: Required` | Empty values **succeed quietly** in `helm --set` and in text substitution | Re-install with the values set, then `kubectl rollout restart`, because EKS only injects a role at pod start. The runbook now checks the annotation | (same) |
| **2** | 6.5 | ECR login script: `Read-only file system: '/app/.aws'` | The Image Updater pod has a read-only root filesystem and `HOME=/app`, and the AWS CLI must write a cache under `$HOME/.aws` | `export HOME=/tmp` **inside the script only**. The updater itself needs `HOME=/app` for its git and SSH config | infra `a912fc4` |
| **3** | 10 | The pipeline failed in the same second it was created, with 0 jobs | GitLab.com requires identity verification before new accounts use shared runners, separate from sign-up | The user verified, then *Run pipeline*. Documented in troubleshooting | infra `4a6cb31` |
| **4** | 10 | `scan` failed: **CRITICAL** `libssl3` CVE-2026-31789 | Even the newest `distroless/nodejs22-debian12` still shipped the unpatched OpenSSL | Moved to `nodejs22-debian13`, which scans clean. **The gate was not weakened.** Checked locally with CI's exact Trivy command | app `54142d5` |
| **5** | 10 | `push`: `the following arguments are required: --web-identity-token` | `aws sts assume-role-with-web-identity` has no `--web-identity-token-file` option | Set `AWS_WEB_IDENTITY_TOKEN_FILE` and let the SDK assume `AWS_ROLE_ARN` itself, the same mechanism IRSA uses. Credentials never pass through a shell variable | app `7bba699` |
| **6** | 10 | Pod `CreateContainerConfigError: image has non-numeric user (nonroot), cannot verify user is non-root` | `runAsNonRoot` can only be enforced against a numeric UID | `runAsUser: 65532` / `runAsGroup: 65532` in the pod spec | gitops `e3a7389` |
| **7** | 10 | Image Updater's commit added an `image.name` key and stripped blank lines | With no `app.helm.image-name` set, it invents a key | Annotation `app.helm.image-name: image.repository`; renamed the stray key so later commits change only the tag | gitops `e3a7389` |

### Operator slip (no code change)
In Step 11, prod was **synced before its PR was merged**. ArgoCD faithfully
released what `main` said, which was still `REPLACE_ME`, and 3 pods went to
`ImagePullBackOff`. Merging PR #1 and syncing again fixed it. It's worth
keeping in the demo: *sync releases git, not intent.*

### Assistant-side gotchas (Git Bash on Windows)
Git Bash rewrites anything that looks like a path, so `/scripts/ecr-login.sh`,
`/etc/rancher/...` and `/aws/eks/...` became `C:/Program Files/Git/...`.
Prefix with `MSYS_NO_PATHCONV=1`. This briefly made a working script look
broken.

---

## 6. Learnings

### About verification
1. **Run it in the real place.** Two of the worst bugs (#2 and #6) were
   invisible to every render and lint. Running `ecr-login.sh` inside the
   actual pod took ten seconds and caught a failure that would otherwise have
   looked like "dev never updates", with no error anywhere.
2. **Prove the permission, not just the login.** `ClusterSecretStore: Valid`
   only proves authentication. A throwaway ExternalSecret proved the IAM
   policy could actually read the secret.
3. **A single-container k3s cluster** is free and catches CRD and API drift
   before you pay for EKS.
4. **Look for silent failures.** Empty variables, a registry string that
   doesn't match, and a missing ImageUpdater CR all *succeed* quietly and then
   do nothing. Print values in brackets and check for exact string equality.

### About dependencies
5. **Pin chart versions.** Two major upstream changes (Image Updater v1 and
   ESO v1beta1 removal) would each have broken an unpinned install. Bump on
   purpose, re-render, and update the docs in the same commit.
6. **Base images rot.** A clean image last month can carry a CRITICAL CVE
   today, and "latest" of the same base may not have the fix yet. Moving to a
   newer distribution line can be the only fix.

### About security design
7. **Keep the gate strict.** The Trivy gate did its job on the first real
   build. The fix was a better base image, not `--exit-code 0`.
8. **Prefer SDK-native federation.** Letting the AWS SDK assume the role from
   `AWS_ROLE_ARN` plus `AWS_WEB_IDENTITY_TOKEN_FILE` is simpler than
   hand-rolling `assume-role` and parsing credentials, and it keeps secrets out
   of shell variables. CI and IRSA now work the same way.
9. **Numeric UIDs.** `USER nonroot` reads well but cannot be enforced by
   `runAsNonRoot`. State `65532` in the pod spec, and ideally in the
   Dockerfile too.
10. **The session name is an audit trail.**
    `gitlab-<project>-<pipeline>` in the assumed-role ARN lets CloudTrail tie
    every ECR push to one pipeline.

### About GitOps
11. **The promotion model held.** Only dev was annotated *and* selected by the
    ImageUpdater, so staging and prod never moved without a human. Two locks
    on one door.
12. **Merge, then sync.** Manual sync releases whatever git says. Syncing
    early releases the old state.
13. **Hand-applied Applications don't update from git.** Changing an
    annotation in `apps/root/` needs a `kubectl apply`. An app-of-apps would
    remove that step.
14. **Machine-written files need the machine's shape.** Hand edits to
    `values-dev.yaml` should match how Image Updater writes it, or every
    deploy commit carries formatting noise.

### About cost and operations
15. **Teardown order is not optional.** Delete Applications, then Services,
    then **wait** for NLBs *and* their ENIs to reach 0 (3 / 0 / 6 → 0 / 0 / 0),
    then `destroy`. It completed with no `DependencyViolation`.
16. **SPOT reclamation is real, even in a 3-hour session.** Both nodes were
    replaced mid-deploy, and the platform recovered on its own. With one node
    at 16/17 pods, a single survivor cannot hold everything, so expect brief
    `Pending` pods during a replacement.
17. **Budget for the unexpected.** The runbook estimates about 90 minutes. The
    first real run took about 3 hours, mostly spent finding and fixing the
    issues above. That was still only ~$0.70.

### About Windows
18. PowerShell 5.1 has quirks: `-chdir=$TF` doesn't expand, `.ps1` files must
    stay ASCII, and the system PATH wins over the user PATH. The runbook now
    gives PowerShell forms that were tested on this machine.

---

## 7. Follow-ups

| Item | Why |
|---|---|
| Dockerfile `USER nonroot` → `USER 65532` | Makes the image valid under any non-root policy, not just this chart. It also works as a rehearsal second deploy |
| Promote staging through a PR next time | `538dba1` went straight to `main`, so the review step was skipped |
| Consider `node_desired_size = 3` for long demos | 30/34 pod slots, one node at 16/17. Costs about +$0.016/hr |
| Consider an app-of-apps for `apps/root/` | Removes the manual re-apply when Application manifests change |
| Note the GitLab trial end (2026-10-23) | After it the mirror stops. Push to GitLab directly or re-enable a paid tier |
| Rehearse [`rollback-demo.md`](rollback-demo.md) | The only part of the demo not yet exercised |

---

## 8. Spinning back up

About 25 minutes plus one pipeline run:

1. `terraform -chdir=infra/envs/cluster apply` (Step 4). Update
   `public_access_cidrs` first if your IP has changed.
2. `aws eks update-kubeconfig ...` (Step 5).
3. Step 6, the platform. Remember `"-chdir=$TF"` in PowerShell, and the
   `HOME=/tmp` line in the Image Updater values.
4. **Run a pipeline first.** The ECR repository was deleted, so tag
   `7bba6991` no longer exists. Push a commit or use *Run pipeline*.
5. `kubectl apply -f gitops/apps/root/` (Step 9). Dev follows the new image,
   and staging and prod need promotion PRs for the new tag.

---

## 9. Commits from this run

| Repo | Commit | Change |
|---|---|---|
| gitops | `fced920` | ImageUpdater CR for dev; ESO `v1` |
| infra | `b30b604` | Pinned charts; review fixes; AL2023 |
| app | `a4202d3` | Correct the claim about the branch-protection trust |
| infra | `e2894ee` | S3 remote state backend |
| infra | `2c67739` | PowerShell `"-chdir=$TF"`; empty-value guards |
| infra | `a912fc4` | `export HOME=/tmp` in the ECR login script |
| gitops | `c808dcb` | Real ECR registry and repo URL |
| infra | `4a6cb31` | GitLab identity verification in troubleshooting |
| app | `2ee86c3` | First pipeline run (visible change) |
| app | `54142d5` | distroless debian12 → debian13 |
| app | `7bba699` | SDK web-identity auth in CI |
| infra | `cfa9363` | Step 10 wording: mirror queue, success line |
| gitops | `19380d2` | *Image Updater:* dev → `7bba6991` |
| gitops | `e3a7389` | `runAsUser 65532`; `image-name` annotation |
| gitops | `538dba1` | Promote to staging |
| gitops | `92c5804` | Merge PR #1: promote to prod |
