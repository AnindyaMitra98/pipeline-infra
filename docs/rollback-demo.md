# Rollback demo runbook

A rehearsed sequence for the demo recording. The story it tells:

> CI passing does not mean the deploy is healthy. The cluster catches what the
> pipeline cannot, and git is what puts it back.

Rehearse this end to end at least once before recording — the ECR poll and the
rolling update both have timing you want to know in advance.

## Before you start

Have these open:

- **ArgoCD UI** — `kubectl port-forward svc/argocd-server -n argocd 8081:443`
- **The app** — `kubectl get svc -n sample-app-dev` and open the NLB hostname
- **A terminal** — `kubectl get pods -n sample-app-dev -w`

Confirm dev is green and note the SHA on the banner. Call this **SHA-A**.

---

## 1. A healthy deploy (~3 min)

Make any visible change to the app — a word in the banner is enough — and push
to GitHub `main`.

Narrate while it runs: GitLab pull-mirrors the commit, the pipeline tests,
builds, scans and pushes to ECR, and **then stops**. Nothing in CI has
permission to touch the cluster.

Argo Image Updater polls ECR (~2 min), sees the new tag, and commits it to
`values-dev.yaml` in the GitOps repo. Show that commit — it is authored by the
updater, and it is the audit trail for the deploy.

ArgoCD syncs. The banner changes colour. Call this **SHA-B**.

## 2. A deploy that passes CI and still fails (~4 min)

Break the *configuration contract*, not the code. In `src/config.js`:

```js
const REQUIRED_VARS = ['APP_GREETING_V2'];   // was: APP_GREETING
```

Nothing in the cluster supplies `APP_GREETING_V2`, so readiness will fail. The
unit tests still pass, because they set their own environment — which is
exactly the blind spot worth showing.

Push it. The pipeline goes **green**. Say so out loud.

Image Updater commits the tag, ArgoCD syncs, and then:

- new pods start but never reach **Ready** (`0/1`)
- the rollout stalls — `maxUnavailable` keeps the old pods serving
- ArgoCD turns the Application **Degraded**
- **the site stays up on SHA-B**

That last point is the one to emphasise. The readiness probe did its job: a
broken version was built, published, and deployed, and never received a single
user request.

Show `kubectl describe pod` — `Readiness probe failed: HTTP 503` — and
`curl <pod>/readyz`, which names the missing variable.

## 3. Rollback, two ways (~3 min)

**Fast — stop the bleeding.**

```bash
argocd app history sample-app-dev
argocd app rollback sample-app-dev <previous-revision>
```

The failing pods are gone in seconds. Good for the GIF.

**Durable — actually fix it.**

Flag the catch before doing it: the rollback changed the *cluster*, but the
GitOps repo still says SHA-C, and the bad image is still the newest tag in ECR.
Left alone, the next Image Updater poll will happily redeploy it. `argocd app
rollback` is a stopgap, not a fix.

```bash
cd gitops
git revert <image-updater-commit>
git push
```

ArgoCD syncs back to SHA-B from git. Now cluster and git agree, and the deploy
is durable.

Finish by reverting the app change too, so `main` is not left broken.

## 4. Close (~1 min)

Back to green: Application **Healthy**, banner on SHA-B, pods `1/1`.

The line to land on: **no `kubectl apply` was run at any point** — not to
deploy, not to roll back. Every state change went through git, and every one of
them is in the log.

---

## Recording notes

- Keep `replicaCount: 2` in dev. With one replica the rollout is over too fast
  to see; with several the ArgoCD tree gets noisy.
- Image Updater's poll interval is the slowest beat in the demo. Either cut
  around it or narrate the architecture while it runs.
- Reset between takes: `git revert` both repos, wait for dev to go green.
- Capture the failure state — red Application, `0/1` pods — as a still. It is
  the strongest single frame in the README.
