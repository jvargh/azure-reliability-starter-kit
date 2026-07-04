# deploy.ps1
# One-stop, PowerShell-runnable deploy of an Azure Monitor Health Model (preview) that
# represents the Checkout/Login application deployed by the SLI demo (../sli-demo).
#
# It follows the two Microsoft Learn how-tos:
#   1. Create a health model            https://learn.microsoft.com/azure/azure-monitor/health-models/create
#   2. Discover entities (App Insights) https://learn.microsoft.com/azure/azure-monitor/health-models/discoveries?tabs=app-insights
#
# What it provisions (all in a NEW resource group, separate from the SLI demo):
#   - A Health Model with a system-assigned managed identity (the "Basics" + "Identity" tabs of the create flow).
#   - Monitoring Reader on the SLI resource group for that identity (so discovery can read telemetry).
#   - A ManagedIdentity authentication setting bound to the system-assigned identity.
#   - An Application Insights topology discovery rule pointing at the SLI demo's Application Insights.
#
# End result: the frontend (Login) and backend (Checkout) components tracked in Application Insights
# are discovered as entities in the health model, with recommended signals attached.
#
# Prerequisites:
#   - Azure CLI logged in (az login) with Contributor on the subscription (or target RGs).
#   - The SLI demo already deployed (../sli-demo/infra/deploy.ps1) so its Application Insights exists.
#     Generate some traffic first (../sli-demo/load/generate-traffic.js) so the App Insights topology
#     has components and dependencies to discover.
#
# Usage:
#   ./deploy.ps1
#   ./deploy.ps1 -ResourceGroup rg-healthmodel-demo -Location eastus2 -SliResourceGroup rg-sli-demo
#   ./deploy.ps1 -AppInsightsResourceId "/subscriptions/.../providers/Microsoft.Insights/components/my-ai"

[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-healthmodel-demo',
  # Health models are only available in a subset of regions (Microsoft.CloudHealth provider).
  # Supported: uksouth, canadacentral, centralus, swedencentral, southeastasia, switzerlandnorth,
  #            italynorth, northeurope, germanywestcentral, australiaeast. The monitored SLI app
  #            can live in any region (eastus2 in the SLI demo); the model may be elsewhere.
  [string]$Location = 'centralus',
  [string]$HealthModelName = 'hm-checkout-demo',
  # Where the SLI demo (and its Application Insights) live. Used both to locate App Insights
  # and as the scope for the Monitoring Reader role assignment.
  [string]$SliResourceGroup = 'rg-sli-demo',
  # Optional explicit App Insights resource id. If omitted, the first component in $SliResourceGroup is used.
  [string]$AppInsightsResourceId
)

$ErrorActionPreference = 'Stop'
$api = '2026-05-01-preview'
$mgmt = 'https://management.azure.com'
$authSettingName = 'system-assigned'
$discoveryRuleName = 'appinsights-topology'

function Invoke-ArmPut {
  param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][hashtable]$Body, [string]$Label)
  $tmp = New-TemporaryFile
  try {
    ($Body | ConvertTo-Json -Depth 10) | Set-Content -Path $tmp -Encoding utf8
    $raw = az rest --method put --url $Url --headers 'Content-Type=application/json' --body "@$tmp" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $raw.Trim() }
    Write-Host "    $Label created" -ForegroundColor Green
  }
  finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

# --- Context ---------------------------------------------------------------
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw 'Not logged in. Run: az login' }
Write-Host "==> Subscription: $($ctx.name) ($($ctx.id))" -ForegroundColor Cyan

# --- Health Models CLI extension (preview) ---------------------------------
Write-Host '==> Ensuring the health-models CLI extension is installed' -ForegroundColor Cyan
az extension add --name health-models --allow-preview true --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { az extension add --name health-models --only-show-errors 2>$null | Out-Null }

# --- Verify the SLI resource group exists (source of the workload resources) ---
Write-Host "==> Verifying SLI resource group $SliResourceGroup" -ForegroundColor Cyan
if ((az group exists -n $SliResourceGroup) -ne 'true') {
  throw "SLI resource group '$SliResourceGroup' not found. Deploy the SLI demo first (../sli-demo/infra/deploy.ps1)."
}

# --- Resource group + provider ---------------------------------------------
Write-Host "==> Ensuring resource group $ResourceGroup" -ForegroundColor Cyan
$existingLoc = az group show -n $ResourceGroup --query location -o tsv 2>$null
if ($existingLoc) {
  Write-Host "    already exists in '$existingLoc' (reusing; health model region is set separately)" -ForegroundColor DarkGray
}
else {
  az group create -n $ResourceGroup -l $Location -o none
}

Write-Host '==> Registering resource provider Microsoft.CloudHealth' -ForegroundColor Cyan
az provider register --namespace Microsoft.CloudHealth -o none

# --- 1. Create the health model (Basics + Identity tabs) -------------------
Write-Host "==> Creating health model $HealthModelName with a system-assigned identity" -ForegroundColor Cyan
$hm = az monitor health-models create -g $ResourceGroup -n $HealthModelName -l $Location --system-assigned -o json | ConvertFrom-Json
$hmId = $hm.id
$principalId = $hm.identity.principalId
if (-not $principalId) {
  $hm = az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json | ConvertFrom-Json
  $hmId = $hm.id
  $principalId = $hm.identity.principalId
}
if (-not $hmId) { throw 'Failed to create the health model.' }
Write-Host "    Health model id: $hmId" -ForegroundColor DarkGray
Write-Host "    System identity principalId: $principalId" -ForegroundColor DarkGray

# --- 2. Grant Monitoring Reader on the SLI resource group ------------------
# The discovery identity needs to read telemetry for the resources it represents.
Write-Host "==> Granting Monitoring Reader on $SliResourceGroup to the health model identity" -ForegroundColor Cyan
$sliRgId = az group show -n $SliResourceGroup --query id -o tsv
if (-not $sliRgId) { throw "SLI resource group '$SliResourceGroup' not found." }

$assigned = $false
for ($i = 1; $i -le 6 -and -not $assigned; $i++) {
  $raw = az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role 'Monitoring Reader' `
    --scope $sliRgId 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { $assigned = $true; Write-Host '    Monitoring Reader assigned' -ForegroundColor Green }
  elseif ($raw -match 'RoleAssignmentExists|already exists') { $assigned = $true; Write-Host '    Monitoring Reader already assigned' -ForegroundColor DarkGray }
  else { Write-Host "    identity not replicated yet, retrying ($i/6)..." -ForegroundColor Yellow; Start-Sleep -Seconds 10 }
}
if (-not $assigned) { throw 'Could not assign Monitoring Reader. Check your permissions on the SLI resource group.' }

# --- 3. Authentication setting bound to the system-assigned identity --------
Write-Host '==> Creating authentication setting (system-assigned managed identity)' -ForegroundColor Cyan
Invoke-ArmPut -Url "$mgmt$hmId/authenticationsettings/$authSettingName`?api-version=$api" -Label 'authentication setting' -Body @{
  properties = @{
    authenticationKind  = 'ManagedIdentity'
    managedIdentityName = 'SystemAssigned'
    displayName         = 'System-assigned managed identity'
  }
}

# --- 4. Resource Graph discovery rule (workload App Services + plan) -------
# Discover the workload's Azure resources: the App Services (frontend, backend, OTel collector,
# remote-write proxy) and their App Service plan. A Resource Graph query is used instead of App
# Insights topology so alerting artifacts (alert rules, smart detectors) and App Insights cloud-role
# components are never modeled. Recommended signals are disabled; Resource Health is disabled too
# (unsupported on Free/Shared plans). configure-signals-alerts.ps1 attaches SLI signals to the app
# App Services and a platform-metric uptime signal to the supporting resources.
Write-Host '==> Creating Resource Graph discovery rule (App Services + plan)' -ForegroundColor Cyan
$discoveryKql = "resources | where resourceGroup =~ '$SliResourceGroup' | where type in~ ('microsoft.web/sites','microsoft.web/serverfarms')"
Invoke-ArmPut -Url "$mgmt$hmId/discoveryrules/$discoveryRuleName`?api-version=$api" -Label 'discovery rule' -Body @{
  properties = @{
    specification           = @{
      kind               = 'ResourceGraphQuery'
      resourceGraphQuery = $discoveryKql
    }
    authenticationSetting   = $authSettingName
    displayName             = 'Checkout/Login workload resources'
    discoverRelationships   = 'Enabled'
    addRecommendedSignals   = 'Disabled'
    addResourceHealthSignal = 'Disabled'
  }
}

# --- Done ------------------------------------------------------------------
$portalUrl = "https://portal.azure.com/#@$($ctx.tenantId)/resource$hmId/overview"
Write-Host ''
Write-Host '==> Done. Health model deployed.' -ForegroundColor Green
Write-Host "Health model:     $HealthModelName ($ResourceGroup / $Location)"
Write-Host "Discovers:        $AppInsightsResourceId"
Write-Host "Portal:           $portalUrl"
Write-Host ''
Write-Host 'Discovery runs every 5 minutes. Give it 5-10 minutes, then open the health model'
Write-Host 'in the portal (Graph view) to see the Checkout/Login components as entities.'
Write-Host 'Tip: run the SLI traffic generator first so App Insights has topology + dependencies to discover.'
