# healthmodel-deploy.ps1
# One-stop, PowerShell-runnable deploy of an Azure Monitor Health Model (preview) that
# represents the Checkout/Login application deployed by the SLI demo (../../01-sli-demo).
#
# It follows the two Microsoft Learn how-tos:
#   1. Create a health model             https://learn.microsoft.com/azure/azure-monitor/health-models/create
#   2. Discover entities                 https://learn.microsoft.com/azure/azure-monitor/health-models/discoveries
#
# What it provisions (all in a NEW resource group, separate from the SLI demo):
#   - A Health Model with a system-assigned managed identity (the "Basics" + "Identity" tabs of the create flow).
#   - Monitoring Reader on the SLI resource group for that identity (so discovery can read resource metadata + App Insights).
#   - A ManagedIdentity authentication setting bound to the system-assigned identity.
#   - TWO discovery rules under two parent nodes, to demonstrate both methods on the same workload:
#       * Azure Resource Graph          - App Services + plan from the SLI RG (recommended signals disabled).
#       * Application Insights topology  - the app's cloud-role components + dependencies (recommended signals enabled).
#     configure-signals-alerts.ps1 then attaches the AMW PromQL SLI signals + alerts to the app entities in both nodes.
#
# End result: the frontend (Login) and backend (Checkout) appear under BOTH a Resource Graph node and an
# App Insights topology node, enriched with AMW PromQL SLI signals and health-state alerts.
#
# Prerequisites:
#   - Azure CLI logged in (az login) with Contributor on the subscription (or target RGs).
#   - The SLI demo already deployed (../../01-sli-demo/infra/infra-deploy.ps1) so its App Services and AMW exist,
#     and the SLIs authored (../../01-sli-demo/infra/sli/deploy-sli.ps1) so the AMW holds SLI result series.
#     Generate some traffic first (../../01-sli-demo/load/generate-traffic.js) so those metrics have data.
#
# Usage:
#   ./healthmodel-deploy.ps1                 # interactive: prompts for name / RG / region (Enter = default)
#   ./healthmodel-deploy.ps1 -NonInteractive # use parameter values as-is, no prompts
#   ./healthmodel-deploy.ps1 -ResourceGroup rg-healthmodel-demo -Location eastus2 -SliResourceGroup rg-sli-demo
#   ./healthmodel-deploy.ps1 -AppInsightsResourceId "/subscriptions/.../providers/Microsoft.Insights/components/my-ai"

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
  [string]$AppInsightsResourceId,
  # By default the script prompts for the health model name, resource group, and region (press Enter to
  # accept each [default]). Pass -NonInteractive to skip all prompts and use the parameter values as-is
  # (this is how healthmodel-run-lab.ps1 calls it in Phase 2).
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$api = '2026-05-01-preview'
$mgmt = 'https://management.azure.com'
$authSettingName = 'system-assigned'
$argRuleName = 'resource-graph'
$aiRuleName = 'appinsights-topology'

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

# --- Interactive setup (default) -------------------------------------------
# Prompt for the health model target unless -NonInteractive was passed. Press Enter to accept each
# [default]. The lab runner (healthmodel-run-lab.ps1) passes -NonInteractive because it already
# collected these values in Phase 1.
function Read-Default([string]$Prompt, [string]$Default) {
  $ans = Read-Host ("    {0} [{1}]" -f $Prompt, $Default)
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default } else { return $ans.Trim() }
}
if (-not $NonInteractive) {
  Write-Host '==> Interactive setup (press Enter to accept each [default]; run with -NonInteractive to skip)' -ForegroundColor Cyan
  $HealthModelName = Read-Default 'Health model name' $HealthModelName
  $ResourceGroup = Read-Default 'Health model resource group' $ResourceGroup
  $Location = Read-Default 'Health model region' $Location
  $SliResourceGroup = Read-Default 'SLI resource group (source workload)' $SliResourceGroup
}

# --- Health Models CLI extension (preview) ---------------------------------
Write-Host '==> Ensuring the health-models CLI extension is installed' -ForegroundColor Cyan
az extension add --name health-models --allow-preview true --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { az extension add --name health-models --only-show-errors 2>$null | Out-Null }

# --- Verify the SLI resource group exists (source of the workload resources) ---
Write-Host "==> Verifying SLI resource group $SliResourceGroup" -ForegroundColor Cyan
if ((az group exists -n $SliResourceGroup) -ne 'true') {
  throw "SLI resource group '$SliResourceGroup' not found. Deploy the SLI demo first (../../01-sli-demo/infra/infra-deploy.ps1)."
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

# --- 4. Discovery rules (two methods, one parent node each) ----------------
# This lab shows BOTH supported ways to discover the same workload, each under its own parent node so
# learners can compare them and pick whichever source they have:
#   a) Azure Resource Graph          - imports the workload's Azure resources (App Services + plan) from
#      the SLI resource group. Works whenever the resources exist; no App Insights required.
#   b) Application Insights topology  - imports the app's cloud-role components and their dependency
#      edges from App Insights. Needs App Insights with observed traffic. Recommended signals are
#      enabled here so learners see the auto-added Log Analytics "failed requests" signal.
# Each rule auto-creates a parent entity named after the rule; the model root is linked to both below.
Write-Host '==> Creating Azure Resource Graph discovery rule (App Services + plan)' -ForegroundColor Cyan
$discoveryKql = "resources | where resourceGroup =~ '$SliResourceGroup' | where type in~ ('microsoft.web/sites','microsoft.web/serverfarms')"
Invoke-ArmPut -Url "$mgmt$hmId/discoveryrules/$argRuleName`?api-version=$api" -Label 'Resource Graph discovery rule' -Body @{
  properties = @{
    specification           = @{
      kind               = 'ResourceGraphQuery'
      resourceGraphQuery = $discoveryKql
    }
    authenticationSetting   = $authSettingName
    displayName             = 'Discovered via Azure Resource Graph'
    discoverRelationships   = 'Enabled'
    addRecommendedSignals   = 'Disabled'
    addResourceHealthSignal = 'Disabled'
  }
}

# Resolve the SLI demo's Application Insights for the topology discovery (explicit id, else the first
# component in the SLI RG). If none exists, skip this branch with a warning rather than failing.
if ($AppInsightsResourceId) { $aiId = $AppInsightsResourceId }
else { $aiId = az resource list -g $SliResourceGroup --resource-type 'Microsoft.Insights/components' --query '[0].id' -o tsv 2>$null }

if ($aiId) {
  Write-Host '==> Creating Application Insights topology discovery rule (recommended signals enabled)' -ForegroundColor Cyan
  Invoke-ArmPut -Url "$mgmt$hmId/discoveryrules/$aiRuleName`?api-version=$api" -Label 'App Insights topology discovery rule' -Body @{
    properties = @{
      specification         = @{
        kind                         = 'ApplicationInsightsTopology'
        applicationInsightsResourceId = $aiId
      }
      authenticationSetting = $authSettingName
      displayName           = 'Discovered via Application Insights topology'
      discoverRelationships = 'Enabled'
      addRecommendedSignals = 'Enabled'
    }
  }
}
else {
  Write-Host '    No Application Insights found in the SLI resource group; skipping the topology discovery branch.' -ForegroundColor Yellow
}

# --- 5. Link the model root to each discovery node (health roll-up) --------
# Each discovery rule creates a parent entity (named after the rule) that its discovered entities
# attach under, but the model root (named after the health model) is not linked to those parents by
# default, so the root floats disconnected and reads Unknown. Add an edge to each node now so the
# graph is connected as soon as the entities appear (configure-signals-alerts.ps1 re-applies this).
Write-Host '==> Linking the model root to each discovery node (health roll-up)' -ForegroundColor Cyan
Invoke-ArmPut -Url "$mgmt$hmId/relationships/root-to-resource-graph`?api-version=$api" -Label 'root -> Resource Graph node' -Body @{
  properties = @{ parentEntityName = $HealthModelName; childEntityName = $argRuleName }
}
if ($aiId) {
  Invoke-ArmPut -Url "$mgmt$hmId/relationships/root-to-appinsights-topology`?api-version=$api" -Label 'root -> App Insights node' -Body @{
    properties = @{ parentEntityName = $HealthModelName; childEntityName = $aiRuleName }
  }
}

# --- Done ------------------------------------------------------------------
$portalUrl = "https://portal.azure.com/#@$($ctx.tenantId)/resource$hmId/overview"
Write-Host ''
Write-Host '==> Done. Health model deployed.' -ForegroundColor Green
Write-Host "Health model:     $HealthModelName ($ResourceGroup / $Location)"
Write-Host "Discovers:        Two nodes in '$SliResourceGroup': Azure Resource Graph (App Services + plan) and Application Insights topology"
Write-Host "Portal:           $portalUrl"
Write-Host ''
Write-Host 'Discovery runs every 5 minutes. Give it 5-10 minutes, then open the health model'
Write-Host 'in the portal (Graph view) to see the Checkout/Login components as entities.'
Write-Host 'Tip: run the SLI traffic generator first so App Insights has topology + dependencies to discover.'
