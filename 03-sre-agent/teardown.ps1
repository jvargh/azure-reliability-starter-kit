<#
.SYNOPSIS
  Delete the SRE Agent created by sre-run-lab.ps1. Optionally delete its resource group.
  The SLI demo and the Health Model are never touched.

.DESCRIPTION
  Deletes the Microsoft.App/agents resource, and (with -DeleteResourceGroup) the agent's resource group
  and the resources the deploy auto-created there (managed identity, Log Analytics, Application Insights).
  RBAC role assignments the agent's managed identity held on the target resource groups are removed with
  the identity when the resource group is deleted; without -DeleteResourceGroup, remove them manually if
  desired.

.EXAMPLE
  ./teardown.ps1
  ./teardown.ps1 -ResourceGroup rg-sre-agent -AgentName sre-checkout
  ./teardown.ps1 -DeleteResourceGroup
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sre-agent',
  [string]$AgentName = 'sre-checkout',
  [switch]$DeleteResourceGroup,
  [switch]$Yes   # skip the confirmation prompt
)

$ErrorActionPreference = 'Stop'
$agentType = 'Microsoft.App/agents'

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw 'Not logged in. Run: az login' }
Write-Host "==> Subscription: $($acct.name) ($($acct.id))" -ForegroundColor Cyan

$agentId = az resource list -g $ResourceGroup --resource-type $agentType --query "[?name=='$AgentName'].id | [0]" -o tsv 2>$null

if (-not $Yes) {
  $what = if ($DeleteResourceGroup) { "the resource group '$ResourceGroup' and everything in it" } else { "the SRE Agent '$AgentName'" }
  Write-Host "This will DELETE $what. The SLI demo and Health Model are left intact." -ForegroundColor Yellow
  $ans = Read-Host 'Proceed? (y/N)'
  if ($ans -notmatch '^(y|yes)$') { Write-Host '    Cancelled.'; return }
}

if ($agentId) {
  Write-Host "==> Deleting SRE Agent $AgentName" -ForegroundColor Cyan
  az resource delete --ids $agentId -o none 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Host '    agent deleted' -ForegroundColor Green } else { Write-Host '    agent delete reported an error (may already be gone)' -ForegroundColor Yellow }
}
else { Write-Host "==> SRE Agent '$AgentName' not found in '$ResourceGroup' (already gone?)" -ForegroundColor DarkGray }

if ($DeleteResourceGroup) {
  if ((az group exists -n $ResourceGroup) -eq 'true') {
    Write-Host "==> Deleting resource group $ResourceGroup" -ForegroundColor Cyan
    az group delete -n $ResourceGroup --yes --no-wait -o none
    Write-Host '    delete requested (running in background)' -ForegroundColor Green
  }
  else { Write-Host "==> Resource group '$ResourceGroup' not found" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '==> Teardown complete.' -ForegroundColor Green
