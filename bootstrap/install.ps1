<#
.SYNOPSIS
    Installs the platform components onto a freshly provisioned EKS cluster.

.DESCRIPTION
    Terraform owns AWS; this script owns what runs on the cluster. It reads the
    Terraform outputs from ../envs/cluster so nothing has to be copied by hand,
    then installs, in order:

      1. ArgoCD                  - the GitOps engine
      2. External Secrets Operator + a ClusterSecretStore pointing at AWS
      3. Argo Image Updater      - watches ECR, writes tags back to git
      4. kube-prometheus-stack   - Prometheus + Grafana

    The order matters: Image Updater registers against ArgoCD's API, and the
    app's ExternalSecret needs the CRDs to exist before ArgoCD syncs it.

    Safe to re-run -- every step is `helm upgrade --install` or `kubectl apply`.

.PARAMETER GitHubUser
    GitHub account or org that owns the pipeline-gitops repository.

.PARAMETER GitHubToken
    A GitHub Personal Access Token with `repo` scope. Argo Image Updater needs
    write access to push its tag-bump commits back to the GitOps repo. This is
    the one credential the platform genuinely needs; it is stored only as a
    Kubernetes Secret, never in git.

.EXAMPLE
    .\install.ps1 -GitHubUser my-handle -GitHubToken ghp_xxx
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GitHubUser,
    [Parameter(Mandatory = $true)][string]$GitHubToken,
    [string]$GitOpsRepo = 'pipeline-gitops',
    [string]$GitAuthorName = 'argocd-image-updater',
    [string]$GitAuthorEmail = 'argocd-image-updater@noreply.local'
)

$ErrorActionPreference = 'Stop'

# Chart versions are pinned. These charts move fast and have broken this
# project before: Image Updater 1.x became a CRD-driven controller, and External
# Secrets 0.17+ stopped serving the v1beta1 API. Bump deliberately, re-render
# with `helm template`, and keep docs/usage.md in step.
$ArgoCdChartVersion          = '10.9.2'    # Argo CD v3.5.3
$ExternalSecretsChartVersion = '2.11.0'    # ESO v2.11.0
$ImageUpdaterChartVersion    = '1.3.1'     # Image Updater v1.3.0
$PrometheusStackChartVersion = '91.5.0'

$tfDir = Join-Path $PSScriptRoot '..\envs\cluster'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }

# --- Read the Terraform outputs -------------------------------------------

Write-Step 'Reading Terraform outputs'
$tf = terraform -chdir="$tfDir" output -json | ConvertFrom-Json

$region              = $tf.region.value
$clusterName         = $tf.cluster_name.value
$ecrRepositoryUrl    = $tf.ecr_repository_url.value
$imageUpdaterRoleArn = $tf.image_updater_role_arn.value
$externalSecretsRole = $tf.external_secrets_role_arn.value

# The registry host is the repository URL minus the trailing /<repo-name>.
$ecrRegistry = $ecrRepositoryUrl.Split('/')[0]

Write-Host "Cluster:  $clusterName ($region)"
Write-Host "Registry: $ecrRegistry"

Write-Step 'Pointing kubectl at the cluster'
aws eks update-kubeconfig --region $region --name $clusterName
kubectl get nodes

# --- Helm repositories -----------------------------------------------------

Write-Step 'Adding Helm repositories'
helm repo add argo https://argoproj.github.io/argo-helm | Out-Null
helm repo add external-secrets https://charts.external-secrets.io | Out-Null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts | Out-Null
helm repo update | Out-Null

# --- 1. ArgoCD -------------------------------------------------------------

Write-Step '1/4 Installing ArgoCD'
helm upgrade --install argocd argo/argo-cd `
    --version $ArgoCdChartVersion `
    --namespace argocd --create-namespace `
    --set 'configs.params.server\.insecure=true' `
    --wait --timeout 10m

# Register the GitOps repo with write credentials. Argo Image Updater reuses
# these when it pushes tag-bump commits back to git.
Write-Step 'Registering the GitOps repository with ArgoCD'
$repoUrl = "https://github.com/$GitHubUser/$GitOpsRepo.git"
kubectl create secret generic gitops-repo `
    --namespace argocd `
    --from-literal=type=git `
    --from-literal=url=$repoUrl `
    --from-literal=username=$GitHubUser `
    --from-literal=password=$GitHubToken `
    --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret gitops-repo -n argocd 'argocd.argoproj.io/secret-type=repository' --overwrite

# --- 2. External Secrets Operator -----------------------------------------

Write-Step '2/4 Installing External Secrets Operator'
helm upgrade --install external-secrets external-secrets/external-secrets `
    --version $ExternalSecretsChartVersion `
    --namespace external-secrets --create-namespace `
    --set installCRDs=true `
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$externalSecretsRole" `
    --wait --timeout 10m

Write-Step 'Creating the AWS Secrets Manager ClusterSecretStore'
# Rendered from a template so the region is not hardcoded in the repo.
(Get-Content (Join-Path $PSScriptRoot 'cluster-secret-store.yaml') -Raw) `
    -replace '\$\{AWS_REGION\}', $region | kubectl apply -f -

# --- 3. Argo Image Updater -------------------------------------------------

Write-Step '3/4 Installing Argo Image Updater'
# The auth script turns the IRSA-derived AWS identity into a Docker credential.
# An ECR authorization token base64-decodes to exactly "AWS:<password>", which
# is the `<username>:<password>` format the updater expects on stdout.
$authScript = @'
#!/bin/sh
aws ecr --region "$AWS_REGION" get-authorization-token \
  --output text --query 'authorizationData[].authorizationToken' | base64 -d
'@

$imageUpdaterValues = @"
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: $imageUpdaterRoleArn
extraEnv:
  - name: AWS_REGION
    value: "$region"
authScripts:
  enabled: true
  scripts:
    ecr-login.sh: |
$($authScript -split "`n" | ForEach-Object { "      $_" } | Out-String)
config:
  # Identity on the tag-bump commits Image Updater pushes to the GitOps repo.
  git.user: $GitAuthorName
  git.email: $GitAuthorEmail
  registries:
    - name: ECR
      api_url: https://$ecrRegistry
      prefix: $ecrRegistry
      ping: yes
      insecure: no
      credentials: ext:/scripts/ecr-login.sh
      # ECR tokens are valid for 12h; refresh before they lapse.
      credsexpire: 10h
"@

$valuesPath = Join-Path $env:TEMP 'image-updater-values.yaml'
$imageUpdaterValues | Set-Content -Path $valuesPath -Encoding utf8

helm upgrade --install argocd-image-updater argo/argocd-image-updater `
    --version $ImageUpdaterChartVersion `
    --namespace argocd `
    --values $valuesPath `
    --wait --timeout 10m

Remove-Item $valuesPath -ErrorAction SilentlyContinue

# --- 4. Prometheus + Grafana ----------------------------------------------

Write-Step '4/4 Installing kube-prometheus-stack'
# Storage is deliberately ephemeral: nothing here needs to survive a teardown,
# and skipping PVCs removes the EBS-volume cleanup lag from `terraform destroy`.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
    --version $PrometheusStackChartVersion `
    --namespace monitoring --create-namespace `
    --set grafana.persistence.enabled=false `
    --set prometheus.prometheusSpec.retention=6h `
    --set alertmanager.enabled=false `
    --wait --timeout 15m

# --- Done ------------------------------------------------------------------

Write-Step 'Platform ready'

$argoPassword = kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}'
if ($argoPassword) {
    $argoPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($argoPassword))
}
$grafanaPassword = kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}'
if ($grafanaPassword) {
    $grafanaPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($grafanaPassword))
}

Write-Host @"

Next steps
----------
1. Edit the GitOps repo placeholders, then push:
     charts/sample-app/values.yaml   image.repository -> $ecrRepositoryUrl
     apps/root/*.yaml                <GITHUB_USER>    -> $GitHubUser
                                     <ACCOUNT_ID>...  -> $ecrRegistry

2. Register the three Applications, and the ImageUpdater that selects dev:
     kubectl apply -f ../../gitops/apps/root/

3. Open the UIs (each blocks the terminal; use separate windows):
     kubectl port-forward svc/argocd-server -n argocd 8081:443
       http://localhost:8081    admin / $argoPassword
       (plain http: server.insecure is on, and the tunnel is already encrypted)

     kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
       http://localhost:3000    admin / $grafanaPassword

4. Push a commit to the app repo and watch dev deploy itself.
"@ -ForegroundColor Green
