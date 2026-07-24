<#
.SYNOPSIS
  Tears down the SLI demo infrastructure. Reverse of infra-deploy.ps1 (+ deploy-sli.ps1).

.DESCRIPTION
  Removes, in order:
    1. The tenant-scoped Service Group + SLIs (via sli/teardown-slo.ps1). These live OUTSIDE the
       resource group, so deleting the RG alone would orphan them - they must go first.
    2. The rg-sli-demo resource group and everything in it: the backend/frontend/collector/proxy
       App Services + plan, Azure Monitor Workspace, Log Analytics, Application Insights, the managed
       identity, the Prometheus recording rules, the action group, and any SLI alerts.

  Deleting a resource group is destructive and irreversible. The script lists the resources and asks
  for confirmation unless you pass -Force.

.PARAMETER ResourceGroup
  The SLI demo resource group to delete. Default: rg-sli-demo.

.PARAMETER SkipServiceGroup
  Skip the Service Group / SLI cleanup (use if it is already gone, or you want to keep it).

.PARAMETER Force
  Delete without the interactive confirmation prompt.

.EXAMPLE
  ./infra-teardown.ps1
  ./infra-teardown.ps1 -Force
  ./infra-teardown.ps1 -SkipServiceGroup
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sli-demo',
  [switch]$SkipServiceGroup,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Remove the tenant-scoped Service Group + SLIs first (the RG delete cannot).
# ---------------------------------------------------------------------------
if (-not $SkipServiceGroup) {
  $slo = Join-Path $PSScriptRoot 'sli/teardown-slo.ps1'
  if (Test-Path $slo) {
    Write-Host '==> Removing Service Group + SLIs (sli/teardown-slo.ps1)' -ForegroundColor Cyan
    try { & $slo -ResourceGroup $ResourceGroup }
    catch { Write-Host "    Service Group teardown skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  else { Write-Host '    sli/teardown-slo.ps1 not found; skipping Service Group cleanup.' -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# 2. Delete the resource group (all infra: apps, AMW, LAW, App Insights, identity, rules, alerts).
# ---------------------------------------------------------------------------
if ((az group exists -n $ResourceGroup -o tsv) -ne 'true') {
  Write-Host "==> Resource group $ResourceGroup does not exist. Nothing to delete." -ForegroundColor DarkGray
  return
}

$resources = az resource list -g $ResourceGroup --query "[].{name:name, type:type}" -o json | ConvertFrom-Json
Write-Host "==> Resource group '$ResourceGroup' has $(@($resources).Count) resource(s):" -ForegroundColor Cyan
$resources | ForEach-Object { Write-Host ("    {0,-45} {1}" -f $_.name, $_.type) }

if (-not $Force) {
  $ans = Read-Host "Delete resource group '$ResourceGroup' and ALL its resources? Type 'yes' to confirm"
  if ($ans -ne 'yes') { Write-Host 'Aborted (nothing deleted).' -ForegroundColor Yellow; return }
}

Write-Host "==> Deleting resource group $ResourceGroup" -ForegroundColor Cyan
az group delete -n $ResourceGroup --yes --no-wait -o none
Write-Host '    delete requested (running in background)' -ForegroundColor Green
Write-Host ''
Write-Host 'Teardown complete. Recreate with: ./infra-deploy.ps1  then  ./sli/deploy-sli.ps1' -ForegroundColor Green
