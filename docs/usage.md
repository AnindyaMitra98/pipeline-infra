# Setup guide

Everything needed to take this project from nothing to a working pipeline, in
order. Each step says what you are doing, what to run, and how to confirm it
worked before moving on.

**Every step here is manual.** Nothing is hidden behind a script you have to
trust: the two PowerShell helpers (`install.ps1`, `pre-destroy-cleanup.ps1`)
are offered as shortcuts, but [Step 6](#step-6--install-the-platform) and
[Step 12](#step-12--tearing-down) spell out, command by command, exactly what
they do — so you can run the whole thing by hand, on any shell, stopping to
look at each piece as it lands.

Budget **about 90 minutes** the first time (a little longer doing Step 6 by
hand). Roughly 35 of those are AWS waiting for EKS, so the rest is real work.

> **This costs money.** The cluster runs about **$0.25/hour** — roughly **$0.75
> for a build session**, or **~$185/month** if you leave it up. Tearing down is
> the whole cost story: [read Step 12](#step-12--tearing-down) *before* you
> start, so it isn't a surprise later. Full breakdown in the
> [README](../README.md#cost-and-teardown).

---

## Contents

- [Before you start](#before-you-start)
- [Step 1 — Create the three repositories](#step-1--create-the-three-repositories)
- [Step 2 — Terraform state backend](#step-2--terraform-state-backend)
- [Step 3 — Set up the GitLab mirror](#step-3--set-up-the-gitlab-mirror)
- [Step 4 — Provision AWS](#step-4--provision-aws)
- [Step 5 — Connect to the cluster](#step-5--connect-to-the-cluster)
- [Step 6 — Install the platform](#step-6--install-the-platform)
  - [6.0 Capture the Terraform outputs](#60-capture-the-terraform-outputs)
  - [6.1 Add the Helm repositories](#61-add-the-helm-repositories)
  - [6.2 Install ArgoCD](#62-install-argocd)
  - [6.3 Give ArgoCD write access to the GitOps repo](#63-give-argocd-write-access-to-the-gitops-repo)
  - [6.4 Install External Secrets Operator](#64-install-external-secrets-operator)
  - [6.5 Install Argo Image Updater](#65-install-argo-image-updater)
  - [6.6 Install Prometheus and Grafana](#66-install-prometheus-and-grafana)
  - [6.7 Collect the passwords and open the UIs](#67-collect-the-passwords-and-open-the-uis)
- [Step 7 — Configure GitLab CI](#step-7--configure-gitlab-ci)
- [Step 8 — Fill in the GitOps placeholders](#step-8--fill-in-the-gitops-placeholders)
- [Step 9 — Register the Applications](#step-9--register-the-applications)
- [Step 10 — First deploy](#step-10--first-deploy)
- [Step 11 — Promote to staging and prod](#step-11--promote-to-staging-and-prod)
- [Step 12 — Tearing down](#step-12--tearing-down)
  - [12.1 Stop ArgoCD from putting it all back](#121-stop-argocd-from-putting-it-all-back)
  - [12.2 Delete the LoadBalancer Services](#122-delete-the-loadbalancer-services)
  - [12.3 Wait for AWS to release the NLBs and ENIs](#123-wait-for-aws-to-release-the-nlbs-and-enis)
  - [12.4 Destroy the infrastructure](#124-destroy-the-infrastructure)
  - [12.5 Confirm nothing is still billing](#125-confirm-nothing-is-still-billing)
- [Troubleshooting](#troubleshooting)

---

## Before you start

### Tools

| Tool | Check | Notes |
|------|-------|-------|
| AWS CLI v2 | `aws --version` | |
| Terraform ≥ 1.5 | `terraform version` | |
| kubectl | `kubectl version --client` | |
| Helm 3 | `helm version` | |
| Docker | `docker ps` | Only for local testing |
| Node.js ≥ 20 | `node --version` | Only for local testing |
| Git | `git --version` | |

### Accounts

- **AWS account** with admin-ish credentials. Confirm:

  ```bash
  aws sts get-caller-identity
  ```

  Note the `Account` number — you will need it in Step 8.

- **GitHub account**, plus a Personal Access Token with **`repo`** scope.
  Create at *Settings → Developer settings → Personal access tokens*. Argo
  Image Updater needs it to push tag commits. Save it somewhere for Step 6.

- **GitLab account** (free tier is fine) at gitlab.com.

### A note on the shell

Terraform, AWS, kubectl and Helm behave the same everywhere, and this guide is
written so one copy of each command works in both bash and PowerShell. Two
things to know:

- **Line continuations.** Multi-line commands below use the bash/zsh trailing
  `\`. In Windows PowerShell, either paste the command as a single line or
  swap each `\` for a backtick.
- **Variables.** Step 6 captures a handful of Terraform outputs into shell
  variables and reuses them. Only the *assignment* differs per shell (both
  forms are given); `$REGION`, `$CLUSTER_NAME` and friends then expand
  identically in bash and PowerShell, so every command after that is one form.

The two `.ps1` scripts are optional conveniences. If you want them, on Windows
use PowerShell; on macOS/Linux install
[PowerShell 7](https://github.com/PowerShell/PowerShell)
(`brew install powershell`). If you would rather not install it, do Steps 6 and
12 by hand — they are written out in full below, and nothing else in this guide
needs PowerShell.

Paths below use `/`. On Windows PowerShell both separators work.

---

## Step 1 — Create the three repositories

This project is **three separate repos**, not a monorepo. That separation is
deliberate: CI, ArgoCD, and Terraform each get their own blast radius.

On GitHub, create three **public** repositories, all empty (no README,
no .gitignore):

| Repository | Contents |
|------------|----------|
| `pipeline-app` | the sample app + GitLab CI config |
| `pipeline-gitops` | Helm chart + ArgoCD Applications |
| `pipeline-infra` | Terraform + docs |

Then push each local folder. From the project root:

```bash
cd app
git init -b main
git add .
git commit -m "Sample app with GitLab CI pipeline"
git remote add origin https://github.com/<YOUR_USER>/pipeline-app.git
git push -u origin main
cd ..
```

Repeat for `gitops/` → `pipeline-gitops` and `infra/` → `pipeline-infra`.

> Run `git init` **inside each of the three folders**, never at the project
> root. The root is not a repository, and making it one would collapse the
> three blast radii back into one.

> `gitops` and `infra` still contain placeholders (`<ACCOUNT_ID>`,
> `<GITHUB_USER>`). Push them anyway — Step 8 fills them in.

**Verify:** all three repos show files on GitHub.

---

## Step 2 — Terraform state backend

Creates an S3 bucket for Terraform state and a DynamoDB table for locking.
This is separate from everything else because state has to exist *before*
anything can use it as a backend.

**You run this once, ever.** It is not part of the spin-up/teardown cycle and
survives `terraform destroy`.

```bash
cd infra/bootstrap-state
terraform init
terraform apply     # type: yes
```

Takes about 30 seconds. Then:

```bash
terraform output -raw backend_config
```

That prints a ready-made backend block. Copy it into
`infra/envs/cluster/backend.tf`, replacing the commented-out block there —
remember to uncomment it.

> Skipping this step is survivable: leave `backend.tf` commented out and
> Terraform keeps state in a local file. Fine on one machine, but you lose
> locking and versioning, and that local file becomes the only record of your
> cluster.

**Verify:**

```bash
aws s3 ls | grep pipeline-portfolio-tfstate
```

---

## Step 3 — Set up the GitLab mirror

GitHub stays the source of truth; GitLab pulls changes and runs CI.

Do this *before* Step 4, because Step 4 needs your GitLab project path to build
the IAM trust policy.

1. On gitlab.com: **New project → Run CI/CD for external repository → GitHub**,
   or create a blank project named `pipeline-app`.
2. Go to **Settings → Repository → Mirroring repositories**:
   - **Git repository URL:** `https://github.com/<YOUR_USER>/pipeline-app.git`
   - **Mirror direction:** **Pull**
   - Save, then click **Update now**.
3. Go to **Settings → Repository → Protected branches** and confirm `main` is
   protected. The IAM trust policy in Step 4 only accepts tokens issued for a
   protected `main`, so CI cannot push to ECR without this.

Note your project path — the part after `gitlab.com/`, e.g.
`your-username/pipeline-app`. You need it next.

**Verify:** GitLab shows your app's files, and *Settings → Repository →
Mirroring* shows a successful last-update time.

---

## Step 4 — Provision AWS

One `terraform apply` creates the VPC, EKS cluster, node group, ECR
repository, the GitLab OIDC trust, all IRSA roles, and the Secrets Manager
entries — about 70 resources.

```bash
cd ../envs/cluster        # from infra/bootstrap-state
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The one value you **must** change:

```hcl
gitlab_allowed_subjects = [
  "project_path:your-username/pipeline-app:ref_type:branch:ref:main"
]
```

Use the GitLab path from Step 3. This controls which pipelines may assume your
AWS role — keep it scoped to one project and branch. A wildcard here would let
any GitLab project on the internet assume your role.

Worth also setting:

```hcl
# Your own IP, so the Kubernetes API isn't open to the world.
public_access_cidrs = ["203.0.113.4/32"]   # curl -s ifconfig.me
```

Then:

```bash
terraform init
terraform plan      # review: ~70 to add, 0 to change, 0 to destroy
terraform apply     # type: yes
```

**This takes 15–20 minutes** — the EKS control plane alone is ~10. Good time to
do Step 7's reading.

**Verify:**

```bash
terraform output
```

You should see `cluster_name`, `ecr_repository_url`, `gitlab_ci_role_arn`, and
the two IRSA role ARNs. These outputs are the seam between the two halves of
the project: Terraform owns AWS, Helm owns the cluster, and this handful of
values is the only thing that crosses. Step 6 consumes them directly.

---

## Step 5 — Connect to the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name pipeline-portfolio
kubectl get nodes
```

**Verify:** two nodes, both `Ready`. If they are `NotReady`, wait a minute —
the VPC CNI is still starting.

---

## Step 6 — Install the platform

Four components, in this order:

1. **ArgoCD** — the GitOps engine
2. **External Secrets Operator** (+ a `ClusterSecretStore` pointing at AWS)
3. **Argo Image Updater** — watches ECR, writes tags back to git
4. **kube-prometheus-stack** — Prometheus + Grafana

The order matters: Image Updater registers against ArgoCD's API, and the app's
`ExternalSecret` needs ESO's CRDs to exist before ArgoCD tries to sync it.

> **Shortcut:** from `infra/bootstrap`,
> `./install.ps1 -GitHubUser <YOUR_USER> -GitHubToken <ghp_...>` does all of
> 6.0–6.7 in one run, about 5 minutes. Everything below is that same work by
> hand. Either way it is re-runnable: every command is `helm upgrade --install`
> or `kubectl apply`, so a failed step can simply be repeated.

Run the rest of this step from `infra/bootstrap` — two files there are used
directly.

### 6.0 Capture the Terraform outputs

Five values get used repeatedly. Read them once into shell variables so the
rest of the step is copy-paste.

**bash / zsh:**

```bash
TF="../envs/cluster"
REGION=$(terraform -chdir=$TF output -raw region)
CLUSTER_NAME=$(terraform -chdir=$TF output -raw cluster_name)
ECR_URL=$(terraform -chdir=$TF output -raw ecr_repository_url)
IMAGE_UPDATER_ROLE=$(terraform -chdir=$TF output -raw image_updater_role_arn)
ESO_ROLE=$(terraform -chdir=$TF output -raw external_secrets_role_arn)
ECR_REGISTRY=${ECR_URL%%/*}          # registry host, minus the /sample-app
```

**PowerShell:**

```powershell
$TF = "../envs/cluster"
$REGION             = terraform -chdir=$TF output -raw region
$CLUSTER_NAME       = terraform -chdir=$TF output -raw cluster_name
$ECR_URL            = terraform -chdir=$TF output -raw ecr_repository_url
$IMAGE_UPDATER_ROLE = terraform -chdir=$TF output -raw image_updater_role_arn
$ESO_ROLE           = terraform -chdir=$TF output -raw external_secrets_role_arn
$ECR_REGISTRY       = $ECR_URL.Split('/')[0]
```

**Verify** — print them and eyeball the account ID and region:

```bash
echo $CLUSTER_NAME $REGION
echo $ECR_REGISTRY
echo $IMAGE_UPDATER_ROLE
echo $ESO_ROLE
```

Then make sure kubectl is aimed at the right cluster before installing
anything into it:

```bash
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME
kubectl config current-context
kubectl get nodes
```

### 6.1 Add the Helm repositories

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

**Verify:** `helm repo list` shows all three.

### 6.2 Install ArgoCD

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set 'configs.params.server\.insecure=true' \
  --wait --timeout 10m
```

`server.insecure=true` makes `argocd-server` serve plain HTTP *inside* the
cluster. That is acceptable here because the only way in is
`kubectl port-forward`, which is already tunnelled over the encrypted
Kubernetes API — there is no public ingress in front of it. It saves fighting
ArgoCD's self-signed certificate on every port-forward.

Keep the escaping on `server\.insecure`: the dot is part of the parameter's
name, and unescaped Helm would read it as nesting.

`--wait` blocks until the pods are Ready, which is what makes 6.3 safe to run
immediately afterwards.

**Verify:**

```bash
kubectl get pods -n argocd            # all Running
```

### 6.3 Give ArgoCD write access to the GitOps repo

ArgoCD needs to *read* the GitOps repo to sync it, and Argo Image Updater
reuses the same credential to *write* tag-bump commits back. One Kubernetes
Secret covers both.

```bash
kubectl create secret generic gitops-repo \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<YOUR_USER>/pipeline-gitops.git \
  --from-literal=username=<YOUR_USER> \
  --from-literal=password=<ghp_your_token> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret gitops-repo -n argocd \
  'argocd.argoproj.io/secret-type=repository' --overwrite
```

The `--dry-run=client | kubectl apply` pipe is what makes this re-runnable —
a plain `kubectl create secret` fails the second time with `AlreadyExists`.

The label is not cosmetic. ArgoCD discovers repository credentials by looking
for `argocd.argoproj.io/secret-type=repository`; without it the Secret is an
unreferenced blob and every sync fails authentication.

That PAT is the **one long-lived credential** in the whole system. It lives
only as a Kubernetes Secret, never in git. Everything else — CI to AWS, and
every in-cluster component to AWS — is short-lived OIDC or IRSA.

**Verify:**

```bash
kubectl get secret gitops-repo -n argocd -o jsonpath='{.metadata.labels}'
```

### 6.4 Install External Secrets Operator

```bash
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ESO_ROLE" \
  --wait --timeout 10m
```

The escaped dots matter here too: `eks\.amazonaws\.com/role-arn` is a single
annotation *key*, not a path into a map.

That one annotation is the entire IRSA mechanism. EKS sees it on the
ServiceAccount, projects a signed token into the pod, and the AWS SDK trades
that token for credentials scoped to `pipeline-app/*` in Secrets Manager.
Nothing else is configured, and no AWS key exists anywhere in the cluster.

Now create the `ClusterSecretStore`. The manifest in this folder carries a
`${AWS_REGION}` placeholder so the region is not hardcoded in a public repo —
substitute it as you apply:

**bash / zsh:**

```bash
sed "s|\${AWS_REGION}|$REGION|" cluster-secret-store.yaml | kubectl apply -f -
```

**PowerShell:**

```powershell
(Get-Content cluster-secret-store.yaml -Raw) -replace '\$\{AWS_REGION\}', $REGION | kubectl apply -f -
```

(Or just open the file, type your region in, and `kubectl apply -f` it — but
don't commit that edit.)

**Verify:**

```bash
kubectl get pods -n external-secrets   # all Running
kubectl get clustersecretstore         # STATUS: Valid
```

`Valid` is the real test of this step: it means ESO assumed its IRSA role and
actually reached AWS Secrets Manager, with no credentials in the cluster. If it
reports `InvalidProviderConfig`, see [Troubleshooting](#troubleshooting).

### 6.5 Install Argo Image Updater

This is the only component that needs a values file, because two things must be
templated in: the IRSA role ARN and your ECR registry host.

Print them:

```bash
echo $IMAGE_UPDATER_ROLE
echo $ECR_REGISTRY
```

Save the following as `image-updater-values.yaml`, replacing
`<IMAGE_UPDATER_ROLE_ARN>` and **both** occurrences of `<ECR_REGISTRY>` (and
the region, if yours is not `us-east-1`):

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <IMAGE_UPDATER_ROLE_ARN>

extraEnv:
  - name: AWS_REGION
    value: "us-east-1"

# ECR does not speak static Docker registry auth. This script turns the
# IRSA-derived AWS identity into a Docker credential on demand: an ECR
# authorization token base64-decodes to exactly "AWS:<password>", which is
# the <username>:<password> format the updater expects on stdout.
authScripts:
  enabled: true
  scripts:
    ecr-login.sh: |
      #!/bin/sh
      aws ecr --region "$AWS_REGION" get-authorization-token \
        --output text --query 'authorizationData[].authorizationToken' | base64 -d

config:
  # Identity on the tag-bump commits Image Updater pushes to the GitOps repo.
  gitCommitUser: argocd-image-updater
  gitCommitMail: argocd-image-updater@noreply.local
  registries:
    - name: ECR
      api_url: https://<ECR_REGISTRY>
      prefix: <ECR_REGISTRY>
      ping: yes
      insecure: no
      credentials: ext:/scripts/ecr-login.sh
      # ECR tokens are valid for 12h; refresh before they lapse.
      credsexpire: 10h
```

Render it before installing — this catches indentation mistakes in the embedded
script without waiting for a `CrashLoopBackOff`:

```bash
helm template argocd-image-updater argo/argocd-image-updater \
  -n argocd -f image-updater-values.yaml | head -40
```

You should see your role ARN on the ServiceAccount and the `ecr-login.sh` key
inside the ConfigMap. Then install:

```bash
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --values image-updater-values.yaml \
  --wait --timeout 10m
```

**Verify:**

```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater
kubectl logs -n argocd deploy/argocd-image-updater | head -20
```

The log should show it starting and finding **0** applications to consider —
correct, because the Applications do not exist until Step 9.

### 6.6 Install Prometheus and Grafana

```bash
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.persistence.enabled=false \
  --set prometheus.prometheusSpec.retention=6h \
  --set alertmanager.enabled=false \
  --wait --timeout 15m
```

Storage is deliberately ephemeral. No EBS CSI driver is installed, so a PVC
here would sit `Pending` forever — and more to the point, persistent volumes
are a classic reason `terraform destroy` hangs. Nothing in this stack needs to
outlive the cluster.

This is the slowest install; several minutes is normal.

**Verify:**

```bash
kubectl get pods -n monitoring        # all Running
```

### 6.7 Collect the passwords and open the UIs

Both are generated at install time and stored as Secrets.

**bash / zsh:**

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d ; echo

kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

(`base64 -d` is `base64 -D` on older macOS.)

**PowerShell:**

```powershell
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
  (kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')))

[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
  (kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}')))
```

Copy both somewhere. Then open the UIs — each blocks its terminal, so use
separate windows:

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
#   https://localhost:8081   admin / <argocd password>

kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
#   http://localhost:3000    admin / <grafana password>
```

**Step 6 is done when all four of these look right:**

```bash
kubectl get pods -n argocd            # all Running, incl. image-updater
kubectl get pods -n external-secrets  # all Running
kubectl get pods -n monitoring        # all Running
kubectl get clustersecretstore        # STATUS: Valid
```

---

## Step 7 — Configure GitLab CI

Get your values:

```bash
terraform -chdir=../envs/cluster output gitlab_ci_variables
```

In GitLab: **Settings → CI/CD → Variables**, add all three:

| Key | Value |
|-----|-------|
| `AWS_ROLE_ARN` | from the output |
| `AWS_REGION` | from the output |
| `ECR_REPOSITORY` | from the output |

**Leave all three unmasked and unprotected-flag-free.** They are identifiers,
not secrets. There is no AWS key to add here — that is the entire point of the
OIDC setup. If you ever find yourself pasting an `AKIA...` value into GitLab,
something has gone wrong.

**Verify:** three variables listed, none of them a credential.

---

## Step 8 — Fill in the GitOps placeholders

The GitOps repo ships with placeholders so it can be published publicly without
leaking an account ID. Fill them in now.

Get your registry host:

```bash
terraform -chdir=../envs/cluster output -raw ecr_repository_url
# 123456789012.dkr.ecr.us-east-1.amazonaws.com/sample-app
```

In your **`pipeline-gitops`** clone:

| File | Replace | With |
|------|---------|------|
| `charts/sample-app/values.yaml` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/sample-app` | the full URL above |
| `apps/root/dev-app.yaml` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/sample-app` | the full URL above |
| `apps/root/*.yaml` (all three) | `<GITHUB_USER>` | your GitHub username |

The registry host in `dev-app.yaml`'s `image-list` annotation must match
`values.yaml`'s `image.repository` **character for character** — Image Updater
matches on that string, so a mismatched region or account silently becomes "no
new images found" rather than an error.

Leave `image.tag: "REPLACE_ME"` alone in the values files — dev corrects itself
on the first build, and you will set staging/prod by hand in Step 11.

Render it to check before pushing:

```bash
helm template sample-app charts/sample-app \
  -f charts/sample-app/values.yaml -f charts/sample-app/values-dev.yaml | grep image:
```

Then commit and push.

**Verify:** no `<ACCOUNT_ID>` or `<GITHUB_USER>` remains:

```bash
grep -r "ACCOUNT_ID\|GITHUB_USER" charts/ apps/     # no output = good
```

---

## Step 9 — Register the Applications

From your `pipeline-gitops` clone:

```bash
kubectl apply -f apps/root/
```

Three Applications, one per environment. Their namespaces are created by ArgoCD
itself (`CreateNamespace=true`), so there is nothing to create first.

**Verify:**

```bash
kubectl get applications -n argocd
```

Three Applications listed. Expect dev and staging to be **Degraded** and prod
**Missing** — the `REPLACE_ME` image tag does not exist yet. That is correct at
this stage; Step 10 fixes it.

---

## Step 10 — First deploy

Now the whole thing runs itself.

In your **`pipeline-app`** clone, make a visible change — e.g. in
`src/app.js`, change the `.greeting` text or any styling — then:

```bash
git commit -am "First pipeline run"
git push
```

Watch it move through the system:

1. **GitLab pulls** (within ~1 min, or click *Update now* on the mirror page).
2. **Pipeline runs** — `test → build → scan → push`. Watch under *Build →
   Pipelines*. The `push` job's log shows `assume-role-with-web-identity`
   succeeding with no stored credentials.
3. **Image lands in ECR:**

   ```bash
   aws ecr describe-images --repository-name sample-app \
     --query 'imageDetails[*].imageTags' --output table
   ```

4. **Argo Image Updater notices** (polls every ~2 min) and commits the new tag
   to `values-dev.yaml`. Check your GitOps repo's commit history — you should
   see a commit authored by `argocd-image-updater`. *That commit is the deploy.*

   To watch it decide rather than waiting blind:

   ```bash
   kubectl logs -n argocd deploy/argocd-image-updater -f
   ```

5. **ArgoCD syncs.** dev goes **Healthy**.

Open the app:

```bash
kubectl get svc -n sample-app-dev
# open the EXTERNAL-IP hostname in a browser
```

The NLB takes 2–3 minutes to become resolvable on first creation.

**Verify:** the page shows your commit's short SHA, on a colour derived from it.
You did not run `kubectl apply` to deploy it.

---

## Step 11 — Promote to staging and prod

Promotion is a pull request that copies a known-good tag forward. Automation
cannot do it — staging and prod have no Image Updater annotations.

```bash
# In pipeline-gitops. First pull down Image Updater's commit, then read the
# tag dev is actually running:
git pull
grep -A1 '^image:' charts/sample-app/values-dev.yaml

git switch -c promote/staging
# edit charts/sample-app/values-staging.yaml -> image.tag: "<that tag>"
git commit -am "promote <tag> to staging"
git push -u origin HEAD
```

Open a PR and merge it. **Staging auto-syncs on merge** — review is the gate.

For prod, same again against `values-prod.yaml`. But after merging, prod shows
**OutOfSync** and stops. Releasing it takes a second, separate human action:

```bash
argocd app sync sample-app-prod
# or click Sync in the UI
```

No `argocd` CLI installed? The same thing through kubectl:

```bash
kubectl -n argocd patch application sample-app-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'
```

**Verify:** all three namespaces running, prod with 3 replicas:

```bash
kubectl get pods -n sample-app-dev
kubectl get pods -n sample-app-staging
kubectl get pods -n sample-app-prod
```

Two deliberate human actions stand between a build and production: approving
the merge, and triggering the release.

---

## Step 12 — Tearing down

**Read this before you start the day, not after.**

Your `Service type=LoadBalancer` objects made *Kubernetes* create real NLBs and
network interfaces inside your subnets. Terraform never created them, so it has
no idea they exist — it will get as far as deleting the subnets, hit
`DependencyViolation`, and hang for ~20 minutes before failing.

So the order is: delete the Kubernetes objects, **wait for AWS to actually
finish reclaiming them**, and only then destroy. The waiting is the part people
skip; deleting a Service returns immediately while the AWS-side teardown runs
asynchronously for another minute or two.

> **Shortcut:** from `infra/bootstrap`, `./pre-destroy-cleanup.ps1` does
> 12.1–12.3 and polls until it prints `All clear`. Everything below is the same
> sequence by hand.

If your shell variables from Step 6 have expired, re-capture `REGION` and
`CLUSTER_NAME` using the blocks in [6.0](#60-capture-the-terraform-outputs).

### 12.1 Stop ArgoCD from putting it all back

Delete the Applications first. `selfHeal` is on for dev and staging, so if you
delete a Service while its Application still exists, ArgoCD helpfully recreates
it — along with a brand new load balancer.

```bash
kubectl delete applications --all -n argocd --timeout=120s
```

**Verify:**

```bash
kubectl get applications -n argocd     # No resources found
```

If it hangs, an Application is stuck on its finalizer:

```bash
kubectl patch application <name> -n argocd --type merge \
  -p '{"metadata":{"finalizers":null}}'
```

### 12.2 Delete the LoadBalancer Services

Find them:

```bash
kubectl get svc --all-namespaces \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type' \
  | grep LoadBalancer
```

There should be three — one per environment, named
`sample-app-<env>-sample-app` (ArgoCD uses the Application name as the Helm
release name, and the chart appends its own). Each app namespace holds exactly
one Service, so deleting by namespace is less error-prone than retyping those:

```bash
kubectl delete svc --all -n sample-app-dev --timeout=120s
kubectl delete svc --all -n sample-app-staging --timeout=120s
kubectl delete svc --all -n sample-app-prod --timeout=120s
```

And any Ingresses, which would own load balancers too (this project creates
none, so expect "No resources found"):

```bash
kubectl delete ingress --all --all-namespaces --timeout=120s
```

**Verify:** the `grep LoadBalancer` command above returns nothing.

### 12.3 Wait for AWS to release the NLBs and ENIs

Deleting the Services only *requested* the teardown. Now confirm AWS finished
it. Get the cluster's VPC:

```bash
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo $VPC_ID
```

PowerShell:

```powershell
$VPC_ID = aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text
```

Then run these three until **all of them return `0`**, re-running every ~15
seconds. It usually clears within two minutes.

```bash
# Network/Application load balancers in the cluster's VPC
aws elbv2 describe-load-balancers --region $REGION \
  --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text

# Classic ELBs — a different API, and note the different capitalisation
aws elb describe-load-balancers --region $REGION \
  --query "length(LoadBalancerDescriptions[?VPCId=='$VPC_ID'])" --output text

# The ENIs the load balancers left behind in your subnets
aws ec2 describe-network-interfaces --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=description,Values=ELB *" \
  --query 'length(NetworkInterfaces)' --output text
```

The ENI count is the one that actually blocks `destroy` — a released load
balancer can still be holding interfaces in the subnet for a few seconds after
it disappears from the load balancer list.

If something is stuck past ten minutes, delete the load balancer by hand in the
EC2 console (*Load Balancers*), then re-check the ENI count.

### 12.4 Destroy the infrastructure

Only once all three counts are `0`:

```bash
terraform -chdir=../envs/cluster destroy    # type: yes
```

Takes ~15 minutes.

### 12.5 Confirm nothing is still billing

```bash
aws eks list-clusters
aws ec2 describe-nat-gateways --filter Name=state,Values=available
aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerName'
```

All three should come back empty. Everything is tagged
`Project = pipeline-portfolio`, so Cost Explorer can confirm independently the
next day.

The **state bucket from Step 2 survives** — it is outside this cycle. Deleting
it is a deliberate manual choice (it has `prevent_destroy` set).

### Spinning back up

Steps 4, 5, 6, 9 — about 25 minutes. Steps 1–3, 7 and 8 are one-time.

---

## Troubleshooting

**GitLab pipeline: `Not authorized to perform sts:AssumeRoleWithWebIdentity`**

The trust policy's subject does not match your pipeline. Check that
`gitlab_allowed_subjects` in `terraform.tfvars` exactly matches your project
path, that you pushed to `main`, and that `main` is protected in GitLab. The
`sub` claim appears in the job log — compare it character by character.

**Trivy fails the build on a CRITICAL finding**

Working as designed — nothing reaches ECR. Rebuild on a newer base image
(`node:22-alpine` and the distroless tag in `Dockerfile`). Do not weaken the
gate to get a green pipeline; a real fix is the better story.

**ArgoCD Application stuck `Degraded` with `ImagePullBackOff`**

The tag in the values file does not exist in ECR. Confirm with
`aws ecr describe-images --repository-name sample-app`. For dev, wait for Image
Updater. For staging/prod, you set the tag by hand — check it.

**ArgoCD Application shows `Unknown` / `authentication required`**

The repository Secret from [6.3](#63-give-argocd-write-access-to-the-gitops-repo)
is missing, mislabelled, or holds a stale token. Confirm the label:

```bash
kubectl get secret gitops-repo -n argocd -o jsonpath='{.metadata.labels}'
```

It must include `argocd.argoproj.io/secret-type: repository`, and `url` must
match the Application's `repoURL` exactly, `.git` suffix included.

**Image Updater is not picking up new images**

```bash
kubectl logs -n argocd deploy/argocd-image-updater -f
```

- `no credentials` → the ECR auth script failed; confirm the ServiceAccount
  carries the IRSA annotation:
  `kubectl get sa argocd-image-updater -n argocd -o yaml`
- `failed to push` → the GitHub token lacks `repo` scope or has expired. Update
  the `gitops-repo` Secret (6.3) or re-run `install.ps1` with a fresh token.
- Nothing at all → the `image-list` annotation's registry host must match the
  ECR URL exactly.

**Image Updater pod is `CrashLoopBackOff` right after install**

Almost always the hand-written values file: the `ecr-login.sh` block under
`authScripts.scripts` must stay indented under the `|` literal. Re-check with
`helm template ... -f image-updater-values.yaml` and compare against the file
in [6.5](#65-install-argo-image-updater).

**Pods `Running` but `0/1` Ready**

Readiness is failing, which usually means config. Check:

```bash
kubectl describe pod -n sample-app-dev <pod>     # Readiness probe failed: 503
kubectl get externalsecret -n sample-app-dev     # STATUS should be SecretSynced
```

If the ExternalSecret is not syncing, ESO cannot reach Secrets Manager —
check `kubectl logs -n external-secrets deploy/external-secrets`.

Note that `/healthz` stays 200 here on purpose: a misconfigured pod should be
held out of service, not restart-looped.

**`terraform destroy` hangs on subnets**

You skipped the cleanup in [12.1–12.3](#step-12--tearing-down). Ctrl-C, work
through those, then destroy again. If a load balancer is truly stuck, delete it
in the EC2 console (*Load Balancers*), wait for its ENIs to clear, and retry.

**`ClusterSecretStore` is not `Valid`**

IRSA is not wired up. Confirm the ServiceAccount annotation matches
`terraform output -raw external_secrets_role_arn`:

```bash
kubectl get sa external-secrets -n external-secrets -o yaml
```

and that the cluster's OIDC provider exists
(`aws iam list-open-id-connect-providers`). If you installed ESO before the
annotation was right, re-run the 6.4 `helm upgrade --install` and then restart
the pods — the token is only projected at pod start:

```bash
kubectl rollout restart deploy -n external-secrets
```
