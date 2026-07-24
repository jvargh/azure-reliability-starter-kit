<#
.SYNOPSIS
  Prep + verification for the SRE Agent phase. Registers the required provider, resolves the workload,
  and confirms the SLI + Health Model alerts exist so the SRE Agent has something to ingest.

.DESCRIPTION
  The SRE Agent itself is created in the portal (sre.azure.com); it is not scriptable in this preview.
  This helper does the scriptable prep and prints the exact values you need in the create wizard:
    - registers Microsoft.App (required for the SRE Agent),
    - resolves the backend App Service + host (for the chaos runbooks),
    - resolves the Action Group used by the SLI/Health Model alerts,
    - lists the metric alert rules on the workload so you can confirm alerts will flow.

  Read-only except for the provider registration. Safe to re-run.

.EXAMPLE
  ./wire-alerts.ps1
  ./wire-alerts.ps1 -SliResourceGroup rg-sli-demo -HealthModelResourceGroup rg-healthmodel-demo
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$HealthModelResourceGroup = 'rg-healthmodel-demo',
  [string]$ActionGroupName = 'ag-sli-demo'
)

$ErrorActionPreference = 'Stop'

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw 'Not logged in. Run: az login' }
Write-Host "==> Subscription: $($acct.name) ($($acct.id))" -ForegroundColor Cyan

Write-Host '==> Registering resource provider Microsoft.App (required for the SRE Agent)' -ForegroundColor Cyan
az provider register --namespace Microsoft.App -o none
$state = az provider show --namespace Microsoft.App --query registrationState -o tsv
Write-Host "    Microsoft.App: $state"

Write-Host "==> Resolving the workload in $SliResourceGroup" -ForegroundColor Cyan
$beName = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].name | [0]" -o tsv 2>$null
$feName = az webapp list -g $SliResourceGroup --query "[?contains(name,'-fe-')].name | [0]" -o tsv 2>$null
$beHost = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].defaultHostName | [0]" -o tsv 2>$null
if ($beName) { Write-Host "    Backend (Checkout/Payment): $beName  https://$beHost" -ForegroundColor Green }
else { Write-Host '    Backend App Service not found (deploy ../01-sli-demo first).' -ForegroundColor Yellow }
if ($feName) { Write-Host "    Frontend (Login): $feName" -ForegroundColor Green }

Write-Host "==> Resolving the Action Group $ActionGroupName" -ForegroundColor Cyan
$agId = az monitor action-group show -g $SliResourceGroup -n $ActionGroupName --query id -o tsv 2>$null
if ($agId) { Write-Host "    $agId" -ForegroundColor Green }
else { Write-Host "    '$ActionGroupName' not found in $SliResourceGroup (optional; used for human notification)." -ForegroundColor Yellow }

Write-Host '==> Metric alert rules on the workload (the SRE Agent ingests these)' -ForegroundColor Cyan
foreach ($rg in @($SliResourceGroup, $HealthModelResourceGroup)) {
  $alerts = az monitor metrics alert list -g $rg --query "[].{name:name, enabled:enabled, sev:severity}" -o json 2>$null | ConvertFrom-Json
  if ($alerts -and $alerts.Count -gt 0) {
    Write-Host "    ${rg}:" -ForegroundColor DarkGray
    $alerts | ForEach-Object { Write-Host ("      [{0}] Sev{1}  {2}" -f $(if ($_.enabled) { 'on' } else { 'off' }), $_.sev, $_.name) }
  }
  else { Write-Host "    ${rg}: no metric alert rules found" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '==> Next (portal, one-time): create the SRE Agent at https://sre.azure.com' -ForegroundColor Cyan
Write-Host '    - Region: East US 2'
Write-Host "    - Managed resource groups: $SliResourceGroup and $HealthModelResourceGroup"
Write-Host '    - Permission level: Reader (approval-only)'
Write-Host '    - Incident instructions: paste src/incident-response-plan.md'
Write-Host '    - Connect GitHub: jvargh/azure-reliability-starter-kit (deployment correlation)'
Write-Host '    Then run ./sli-alert-scenario.ps1 to exercise the loop.'
