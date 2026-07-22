# teardown.ps1
# Reverses src/healthmodel-deploy.ps1: deletes the health model (which removes its authentication settings and
# discovery rules), removes the Monitoring Reader role assignment on the SLI resource group, and
# optionally deletes the resource group. The SLI demo (../01-sli-demo) is left untouched.
#
# Usage:
#   ./teardown.ps1
#   ./teardown.ps1 -DeleteResourceGroup
#   ./teardown.ps1 -ResourceGroup rg-healthmodel-demo -SliResourceGroup rg-sli-demo

[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-healthmodel-demo',
  [string]$HealthModelName = 'hm-checkout-demo',
  [string]$SliResourceGroup = 'rg-sli-demo',
  [switch]$DeleteResourceGroup
)

$ErrorActionPreference = 'Stop'

# Capture the identity before deleting the model so we can clean up the role assignment.
$principalId = az monitor health-models show -g $ResourceGroup -n $HealthModelName --query identity.principalId -o tsv 2>$null

Write-Host "==> Deleting health model $HealthModelName" -ForegroundColor Cyan
az monitor health-models delete -g $ResourceGroup -n $HealthModelName --yes -o none 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host '    health model deleted' -ForegroundColor Green }
else { Write-Host '    health model already gone' -ForegroundColor DarkGray }

if ($principalId) {
  Write-Host "==> Removing Monitoring Reader on $SliResourceGroup" -ForegroundColor Cyan
  $sliRgId = az group show -n $SliResourceGroup --query id -o tsv 2>$null
  if ($sliRgId) {
    az role assignment delete --assignee $principalId --role 'Monitoring Reader' --scope $sliRgId -o none 2>$null
    Write-Host '    role assignment removed' -ForegroundColor Green
  }
}

if ($DeleteResourceGroup) {
  Write-Host "==> Deleting resource group $ResourceGroup" -ForegroundColor Cyan
  az group delete -n $ResourceGroup --yes --no-wait -o none
  Write-Host '    delete requested (running in background)' -ForegroundColor Green
}

Write-Host ''
Write-Host '==> Teardown complete.' -ForegroundColor Green
