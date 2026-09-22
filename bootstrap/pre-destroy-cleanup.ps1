<#
.SYNOPSIS
    Removes Kubernetes-owned AWS resources before `terraform destroy`.

.DESCRIPTION
    A Service of type=LoadBalancer makes Kubernetes create a real NLB and a set
    of ENIs in your subnets. Terraform has no idea those exist -- it never
    created them -- so `terraform destroy` gets as far as deleting the subnets
    and then hangs for ~20 minutes before failing with DependencyViolation.

    The fix is to delete the Kubernetes objects first and *wait* for AWS to
    finish reclaiming the load balancers and their ENIs. Deleting the Service
    returns immediately; the AWS-side teardown is asynchronous, which is why
    this script polls rather than just issuing deletes.

    Run this, then `terraform destroy`.

.EXAMPLE
    .\pre-destroy-cleanup.ps1
    terraform -chdir=..\envs\cluster destroy
#>

[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
$tfDir = Join-Path $PSScriptRoot '..\envs\cluster'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }

Write-Step 'Reading Terraform outputs'
$tf = terraform -chdir="$tfDir" output -json | ConvertFrom-Json
$region      = $tf.region.value
$clusterName = $tf.cluster_name.value

# If the cluster is already gone there is nothing to clean up.
$clusterExists = $true
try {
    aws eks describe-cluster --name $clusterName --region $region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $clusterExists = $false }
} catch { $clusterExists = $false }

if (-not $clusterExists) {
    Write-Host "Cluster $clusterName not found -- nothing to clean up." -ForegroundColor Yellow
    exit 0
}

aws eks update-kubeconfig --region $region --name $clusterName | Out-Null

# --- Delete the Kubernetes objects that own AWS load balancers -------------

Write-Step 'Deleting LoadBalancer Services and Ingresses'
# Removing the ArgoCD Applications first stops self-heal from recreating the
# Services we are about to delete.
try { kubectl delete applications --all -n argocd --timeout=120s } catch {
    Write-Host 'No ArgoCD Applications to remove.' -ForegroundColor Yellow
}

$services = kubectl get svc --all-namespaces -o json | ConvertFrom-Json
$lbServices = $services.items | Where-Object { $_.spec.type -eq 'LoadBalancer' }

if ($lbServices) {
    foreach ($svc in $lbServices) {
        Write-Host "  deleting svc $($svc.metadata.namespace)/$($svc.metadata.name)"
        kubectl delete svc $svc.metadata.name -n $svc.metadata.namespace --timeout=120s
    }
} else {
    Write-Host '  no LoadBalancer Services found'
}

try { kubectl delete ingress --all --all-namespaces --timeout=120s } catch {
    Write-Host '  no Ingresses to remove' -ForegroundColor Yellow
}

# --- Wait for AWS to actually reclaim them ---------------------------------

Write-Step 'Waiting for load balancers and ENIs to be released'
$vpcId = aws eks describe-cluster --name $clusterName --region $region `
    --query 'cluster.resourcesVpcConfig.vpcId' --output text

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-Date) -lt $deadline) {
    # Any ELBv2 still attached to the cluster's VPC.
    $lbCount = (aws elbv2 describe-load-balancers --region $region `
        --query "length(LoadBalancers[?VpcId=='$vpcId'])" --output text)

    # Classic ELBs are reported by a different API.
    $classicCount = (aws elb describe-load-balancers --region $region `
        --query "length(LoadBalancerDescriptions[?VPCId=='$vpcId'])" --output text)

    # ENIs left behind by the load balancers or the VPC CNI.
    $eniCount = (aws ec2 describe-network-interfaces --region $region `
        --filters "Name=vpc-id,Values=$vpcId" "Name=description,Values=ELB *" `
        --query 'length(NetworkInterfaces)' --output text)

    Write-Host "  load balancers: $lbCount (v2) / $classicCount (classic), ELB ENIs: $eniCount"

    if ($lbCount -eq '0' -and $classicCount -eq '0' -and $eniCount -eq '0') {
        Write-Host "`nAll clear. Safe to run: terraform -chdir=..\envs\cluster destroy" -ForegroundColor Green
        exit 0
    }

    Start-Sleep -Seconds 15
}

Write-Warning @"
Timed out after $TimeoutMinutes minutes with resources still present.
'terraform destroy' may fail on DependencyViolation when deleting subnets.
Check the AWS console for leftover load balancers in VPC $vpcId, then re-run.
"@
exit 1
