# configure-signals-alerts.ps1
# Wires the health model into the SLI Azure Monitor Workspace (AMW) and configures health state:
#   - Grants the health model identity Monitoring Reader on the SLI AMW (PromQL query access).
#   - Taps the AMW where the SLI engine STORES its evaluated results, adding one Azure Monitor
#     workspace (PromQL) signal per SLI to the app's App Service entities:
#       * backend App Service  (Checkout) -> CheckoutAvailabilitySLI + PaymentDependencySLI values
#       * frontend App Service (Login)    -> LoginLatencySLI value
#     Each signal reads the published series ns::<servicegroup>/m::<sli>:value, so the health model
#     and the SLIs report the exact same number.
#   - Configures entity alerts (Degraded + Unhealthy) that fire on health-state change.
#
# Follows:
#   - Signals: https://learn.microsoft.com/azure/azure-monitor/health-models/signals?tabs=azuremonitorworkspace
#   - Alerts:  https://learn.microsoft.com/azure/azure-monitor/health-models/alerts
#
# Run healthmodel-deploy.ps1 first (model + discovered entities) and author the SLIs
# (../../01-sli-demo/infra/sli/deploy-sli.ps1) so the ns::.../:value series exist. Entities are enriched
# in place; the Resource Graph discovery keeps them discovered on its 5-minute cycle.
#
# Usage:
#   ./configure-signals-alerts.ps1
#   ./configure-signals-alerts.ps1 -ActionGroupId "/subscriptions/.../actionGroups/my-ag"

[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-healthmodel-demo',
  [string]$HealthModelName = 'hm-checkout-demo',
  [string]$SliResourceGroup = 'rg-sli-demo',
  # The Service Group whose published SLI series to use. The AMW can hold ns::<sg>/m::<sli>:value series
  # from several service groups; pinning to this one avoids attaching a stale/empty namespace's series.
  [string]$ServiceGroup,
  # Optional explicit AMW resource id. If omitted, the first Monitor account in $SliResourceGroup is used.
  [string]$AmwResourceId,
  # Optional action group to notify when an entity alert fires (up to 5 supported by the API).
  [string]$ActionGroupId,
  # Name patterns identifying the app's App Service entities (frontend = Login, backend = Checkout).
  [string]$FrontendLike = '*-fe-*',
  [string]$BackendLike = '*-be-*'
)

$ErrorActionPreference = 'Stop'
$api = '2026-05-01-preview'
$mgmt = 'https://management.azure.com'
$authSettingName = 'system-assigned'

# Deep-clone a parsed-JSON object to a hashtable, dropping runtime/read-only fields and nulls so the
# result can be PUT back safely.
function ConvertTo-CleanHashtable {
  param($Value, [string[]]$Drop)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IEnumerable]) {
    return @($Value | ForEach-Object { ConvertTo-CleanHashtable -Value $_ -Drop $Drop })
  }
  if ($Value -is [psobject]) {
    $h = @{}
    foreach ($p in $Value.PSObject.Properties) {
      if ($Drop -contains $p.Name) { continue }
      if ($null -eq $p.Value) { continue }
      $h[$p.Name] = ConvertTo-CleanHashtable -Value $p.Value -Drop $Drop
    }
    return $h
  }
  return $Value
}

function Invoke-ArmPut {
  param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][hashtable]$Body, [string]$Label)
  $tmp = New-TemporaryFile
  try {
    ($Body | ConvertTo-Json -Depth 20) | Set-Content -Path $tmp -Encoding utf8
    $raw = az rest --method put --url $Url --headers 'Content-Type=application/json' --body "@$tmp" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $raw.Trim() }
    Write-Host "    $Label updated" -ForegroundColor Green
  }
  finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# --- Resolve resources -----------------------------------------------------
$hm = az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json 2>$null | ConvertFrom-Json
if (-not $hm) { throw "Health model '$HealthModelName' not found in '$ResourceGroup'. Run healthmodel-deploy.ps1 first." }
$hmId = $hm.id
$principalId = $hm.identity.principalId

if (-not $AmwResourceId) {
  Write-Host "==> Locating Azure Monitor Workspace in $SliResourceGroup" -ForegroundColor Cyan
  $AmwResourceId = az resource list -g $SliResourceGroup --resource-type 'Microsoft.Monitor/accounts' --query '[0].id' -o tsv
  if (-not $AmwResourceId) { throw "No Azure Monitor Workspace (Microsoft.Monitor/accounts) found in '$SliResourceGroup'." }
}
Write-Host "    AMW: $AmwResourceId" -ForegroundColor DarkGray

# --- AMW query access for the health model identity ------------------------
# The AMW (PromQL) signals QUERY the workspace's Prometheus data plane, which requires
# 'Monitoring Data Reader'. 'Monitoring Reader' alone is control-plane only, so the signals
# would read Unknown with "Signal error". Grant both (Data Reader is the one that matters).
Write-Host '==> Ensuring AMW query roles (Monitoring Data Reader + Monitoring Reader) for the health model identity' -ForegroundColor Cyan
foreach ($role in @('Monitoring Data Reader', 'Monitoring Reader')) {
  $raw = az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role $role --scope $AmwResourceId 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { Write-Host "    $role assigned" -ForegroundColor Green }
  elseif ($raw -match 'RoleAssignmentExists|already exists') { Write-Host "    $role already assigned" -ForegroundColor DarkGray }
  else { Write-Host "    warning ($role): $($raw.Trim())" -ForegroundColor Yellow }
}

# Note: recommended signals are left as the deploy configured them (disabled on the Resource Graph
# node, enabled on the App Insights topology node so learners see the auto-added Log Analytics
# "failed requests" signal). The SLI signals below are added alongside them, not instead of them.

# --- Discover the published SLI result series in the AMW -------------------
# The SLI engine writes each evaluated SLI to the AMW as ns::<servicegroup>/m::<sli>:value.
# Discover the exact series names so the signals reference the real stored SLI values.
Write-Host '==> Discovering published SLI result series in the AMW' -ForegroundColor Cyan
$promEp = az resource show --ids $AmwResourceId --query 'properties.metrics.prometheusQueryEndpoint' -o tsv
$promTok = az account get-access-token --resource 'https://prometheus.monitor.azure.com' --query accessToken -o tsv
$allNames = (Invoke-RestMethod -Uri "$promEp/api/v1/label/__name__/values" -Headers @{ Authorization = "Bearer $promTok" }).data
# The AMW can hold the same SLI series under several service-group namespaces. When a Service Group is
# known, pin to ns::<sg-lower>/m::<sli>:value exactly; otherwise fall back to the first namespace match.
function Find-Series([string]$suffix, [switch]$Optional) {
  if ($ServiceGroup) {
    $exact = $allNames | Where-Object { $_ -eq "ns::$($ServiceGroup.ToLower())/m::$suffix" } | Select-Object -First 1
    if ($exact) { return $exact }
    # Optional series (uptime/downtime, which only exist for window-based SLIs) may legitimately be
    # absent for request-based SLIs; do not warn or cross into another service group's namespace.
    if ($Optional) { return $null }
    Write-Host "    warning: no series ns::$($ServiceGroup.ToLower())/m::$suffix; falling back to any namespace" -ForegroundColor Yellow
  }
  $allNames | Where-Object { $_ -like "ns::*/m::$suffix" } | Select-Object -First 1
}
# Return the PromQL that yields the SLI COMPLIANCE % (higher is better) for a given SLI.
# Request-based SLIs (availability) publish :value already as a percentage. Window-based SLIs
# (for example latency) publish :value as the raw measured signal (seconds) plus :uptime/:downtime
# window counts, so their compliance % is 100 * uptime / (uptime + downtime).
function Get-SliComplianceQuery([string]$sliLower) {
  $val = Find-Series "${sliLower}:value"
  if (-not $val) { return $null }
  $up = Find-Series "${sliLower}:uptime" -Optional
  $down = Find-Series "${sliLower}:downtime" -Optional
  if ($up -and $down) {
    return "100 * sum(last_over_time({__name__=`"$up`"}[1h])) / (sum(last_over_time({__name__=`"$up`"}[1h])) + sum(last_over_time({__name__=`"$down`"}[1h])))"
  }
  return "last_over_time({__name__=`"$val`"}[1h])"
}
$checkoutQuery = Get-SliComplianceQuery 'checkoutavailabilitysli'
$loginQuery = Get-SliComplianceQuery 'loginlatencysli'
$paymentQuery = Get-SliComplianceQuery 'paymentdependencysli'
foreach ($p in @(@{n = 'CheckoutAvailabilitySLI'; v = $checkoutQuery }, @{n = 'LoginLatencySLI'; v = $loginQuery }, @{n = 'PaymentDependencySLI'; v = $paymentQuery })) {
  if ($p.v) { Write-Host "    $($p.n): found" -ForegroundColor DarkGray }
  else { Write-Host "    $($p.n): NOT FOUND (author the SLIs first: ../../01-sli-demo/infra/sli/deploy-sli.ps1)" -ForegroundColor Yellow }
}

# All SLI compliance values are percentages where higher is better, so 'lower than' thresholds apply
# (degraded < 100, unhealthy < 99). last_over_time([1h]) returns the most recent published value so a
# brief idle gap between traffic and the next SLI evaluation does not error the signal (it reads
# Unknown only if the SLI has published nothing for an hour).
function New-SliSignal([string]$name, [string]$display, [string]$query) {
  @{
    name            = $name
    displayName     = $display
    signalKind      = 'PrometheusMetricsQuery'
    queryText       = $query
    refreshInterval = 'PT1M'
    timeGrain       = 'PT5M'
    dataUnit        = 'Percent'
    evaluationRules = @{
      degradedRule  = @{ operator = 'LessThan'; threshold = 99 }
      unhealthyRule = @{ operator = 'LessThan'; threshold = 95 }
    }
  }
}

# Tuned HTTP 5xx recommended signal for App Service (Microsoft.Web/sites) entities. The discovery-added
# default trips Unhealthy at >0 5xx, which is far too strict for a demo that intentionally emits a few
# 5xx (payment 502s, chaos injection). Providing this signal in the entity PUT also stops discovery from
# re-adding the noisy default (recommended signals are only re-added when missing). Thresholds are 5xx
# COUNT over a 5-minute window: Degraded > 30, Unhealthy > 150, so normal payment-failure noise stays
# green while a real error spike (or the chaos demo) still turns the entity red.
function New-Http5xxSignal {
  @{
    name            = 'http5xx'
    displayName     = 'Http5xx'
    signalKind      = 'AzureResourceMetric'
    metricNamespace = 'Microsoft.Web/sites'
    metricName      = 'Http5xx'
    aggregationType = 'Total'
    refreshInterval = 'PT1M'
    timeGrain       = 'PT5M'
    dataUnit        = 'Count'
    evaluationRules = @{
      degradedRule  = @{ operator = 'GreaterThan'; threshold = 30 }
      unhealthyRule = @{ operator = 'GreaterThan'; threshold = 150 }
    }
  }
}

# --- Locate the app's App Service entities ---------------------------------
$entities = az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o json | ConvertFrom-Json
# Identify the frontend (Login) and backend (Checkout) App Services by name; exclude the plan
# (a serverfarm named '*-plan').
# Match ALL frontend/backend entities across BOTH discovery nodes: the Resource Graph node names them
# after the App Service ARM resources (slidemo-fe-*, slidemo-be-*), while the App Insights topology
# node names them after the cloud roles (sli-demo-frontend, sli-demo-backend). Exclude the plan.
$feEntities = @($entities | Where-Object { ($_.properties.displayName -like $FrontendLike -or $_.properties.displayName -like '*frontend*') -and $_.properties.displayName -notlike '*-plan' })
$beEntities = @($entities | Where-Object { ($_.properties.displayName -like $BackendLike -or $_.properties.displayName -like '*backend*') -and $_.properties.displayName -notlike '*-plan' })

# Signal assignments: Checkout (backend) carries the Checkout availability + Payment dependency SLIs
# (checkout depends on payment); Login (frontend) carries the Login latency SLI.
$backendSignals = @()
if ($checkoutQuery) { $backendSignals += (New-SliSignal 'checkout-availability-sli' 'Checkout availability SLI (AMW)' $checkoutQuery) }
if ($paymentQuery) { $backendSignals += (New-SliSignal 'payment-dependency-sli' 'Payment dependency SLI (AMW)' $paymentQuery) }
$frontendSignals = @()
if ($loginQuery) { $frontendSignals += (New-SliSignal 'login-latency-sli' 'Login latency SLI (AMW)' $loginQuery) }

$alerts = @{
  degraded  = @{ severity = 'Sev2'; description = 'Health model entity entered Degraded state.' }
  unhealthy = @{ severity = 'Sev1'; description = 'Health model entity entered Unhealthy state.' }
}
if ($ActionGroupId) {
  $alerts.degraded.actionGroupIds = @($ActionGroupId)
  $alerts.unhealthy.actionGroupIds = @($ActionGroupId)
}

$targets = @()
foreach ($e in $beEntities) { $targets += @{ entity = $e; label = "Checkout (backend): $($e.properties.displayName)"; signals = $backendSignals } }
foreach ($e in $feEntities) { $targets += @{ entity = $e; label = "Login (frontend): $($e.properties.displayName)"; signals = $frontendSignals } }

# Attach the SLI signals to each app entity in BOTH discovery nodes. This PUT sets the entity's
# azureMonitorWorkspace signal group and rebuilds the azureResource group where the entity is a real
# Azure resource (keeping the exact azureResourceId since changing it is rejected for dynamic entities,
# Resource Health disabled). For App Service entities it also attaches a TUNED Http5xx signal so the
# noisy discovery default (Unhealthy at >0 5xx) is replaced and not re-added (recommended signals are
# only re-added when missing). The App Insights node's recommended Log Analytics "failed requests"
# signal lives on the cloud-role component entities, not these, and discovery keeps re-adding it there.
$appNames = @()
foreach ($t in $targets) {
  if (-not $t.entity) { Write-Host "==> App Service for $($t.label) not found yet; skipping (allow ~5 min for discovery)." -ForegroundColor Yellow; continue }
  if (-not $t.signals -or $t.signals.Count -eq 0) { Write-Host "==> No SLI series for $($t.label); skipping (author the SLIs first)." -ForegroundColor Yellow; continue }
  $dn = $t.entity.properties.displayName
  $appNames += $t.entity.name
  $signalNames = ($t.signals | ForEach-Object { $_.displayName }) -join ', '
  Write-Host "==> $($t.label) = '$dn': $signalNames" -ForegroundColor Cyan
  $arId = $t.entity.properties.signalGroups.azureResource.azureResourceId
  $props = @{
    displayName  = $dn
    impact       = 'Standard'
    signalGroups = @{
      azureMonitorWorkspace = @{
        authenticationSetting           = $authSettingName
        azureMonitorWorkspaceResourceId = $AmwResourceId
        signals                         = @($t.signals)
      }
    }
    alerts       = $alerts
  }
  if ($t.entity.properties.icon) { $props.icon = @{ iconName = $t.entity.properties.icon.iconName } }
  if ($arId) {
    $ar = @{ authenticationSetting = $authSettingName; azureResourceId = $arId; resourceHealth = @{ enabled = 'Disabled' } }
    # App Service (Microsoft.Web/sites) entities: attach the tuned Http5xx so the noisy discovery
    # default (Unhealthy at >0 5xx) is replaced and not re-added on the next discovery cycle.
    if ($arId -match '/sites/') { $ar.signals = @(New-Http5xxSignal) }
    $props.signalGroups.azureResource = $ar
  }
  Invoke-ArmPut -Url "$mgmt$hmId/entities/$($t.entity.name)`?api-version=$api" -Label "$dn ($signalNames)" -Body @{ properties = $props }
}

# --- Give the supporting resources a real uptime signal --------------------
# The supporting resources (OTel collector, remote-write proxy, App Service plan) are valid Azure
# resources but have no SLI. The built-in availability/uptime signal is Azure Resource Health, which
# is only supported on Basic+ App Service plans. So detect the plan tier and PREFER Resource Health
# when supported; on Free/Shared fall back to a platform-metric uptime signal (HTTP 2xx for App
# Services, CPU % for the plan). All stay impact=Standard so a down pipeline resource is visible.
$rules = az monitor health-models discovery-rule list -g $ResourceGroup --health-model-name $HealthModelName -o json | ConvertFrom-Json
$parentEntities = @($rules | ForEach-Object { $_.properties.entityName } | Where-Object { $_ } | Select-Object -Unique)
# Give each source node a clear display name so learners can tell the two discovery methods apart.
$parentLabels = @{ 'resource-graph' = 'Workload via Azure Resource Graph'; 'appinsights-topology' = 'Workload via Application Insights topology' }
foreach ($pe in $parentEntities) {
  if ($parentLabels[$pe]) {
    az monitor health-models entity update -g $ResourceGroup --health-model-name $HealthModelName `
      --entity-name $pe --set "properties.displayName=$($parentLabels[$pe])" -o none 2>$null
  }
}
# Resource Health is unsupported on Free/Shared App Service plans (assumes the workload shares one plan).
$planTier = az resource list -g $SliResourceGroup --resource-type 'Microsoft.Web/serverfarms' --query '[0].sku.tier' -o tsv 2>$null
$rhSupported = $planTier -and ($planTier -notin @('Free', 'Shared'))
Write-Host "==> App Service plan tier: $planTier (Resource Health supported: $rhSupported)" -ForegroundColor Cyan
$skip = @($appNames) + @($parentEntities) + @($HealthModelName)
foreach ($e in $entities) {
  if ($skip -contains $e.name) { continue }
  $arId = $e.properties.signalGroups.azureResource.azureResourceId
  if (-not $arId) { Write-Host "    '$($e.properties.displayName)' has no azureResourceId; skipping" -ForegroundColor DarkGray; continue }
  $dn = $e.properties.displayName
  # Only App Service sites and their plan support these uptime signals. Other discovered resource
  # types (for example the App Insights "failure anomalies" smart detector alert rule) return a
  # "Signal error" for Resource Health, so clear their signals (leaving them Unknown, but without an
  # error) instead of attaching a signal that can never evaluate.
  if ($arId -notmatch '/sites/|/serverfarms/') {
    Write-Host "==> Clearing signals on '$dn' (resource type does not support an uptime signal)" -ForegroundColor Cyan
    $props = @{ displayName = $dn; impact = 'Standard'; signalGroups = @{ azureResource = @{ authenticationSetting = $authSettingName; azureResourceId = $arId; resourceHealth = @{ enabled = 'Disabled' } } } }
    if ($e.properties.icon) { $props.icon = @{ iconName = $e.properties.icon.iconName } }
    Invoke-ArmPut -Url "$mgmt$hmId/entities/$($e.name)`?api-version=$api" -Label "clear $dn" -Body @{ properties = $props }
    continue
  }
  if ($rhSupported) {
    # Basic+ tier: use the built-in Resource Health availability signal (no metric query needed).
    $azureResource = @{ authenticationSetting = $authSettingName; azureResourceId = $arId; resourceHealth = @{ enabled = 'Enabled' } }
    $what = 'Resource Health'
  }
  else {
    # Free/Shared tier: Resource Health is unsupported, so use a platform-metric uptime signal.
    if ($arId -match '/serverfarms/') {
      $sig = @{ name = 'plan-cpu'; displayName = 'CPU % (App Service plan)'; signalKind = 'AzureResourceMetric'; metricNamespace = 'Microsoft.Web/serverfarms'; metricName = 'CpuPercentage'; aggregationType = 'Average'; refreshInterval = 'PT1M'; timeGrain = 'PT5M'; dataUnit = 'Percent'; evaluationRules = @{ degradedRule = @{ operator = 'GreaterThan'; threshold = 80 }; unhealthyRule = @{ operator = 'GreaterThan'; threshold = 95 } } }
    }
    else {
      $sig = @{ name = 'uptime-http2xx'; displayName = 'Uptime (HTTP 2xx)'; signalKind = 'AzureResourceMetric'; metricNamespace = 'Microsoft.Web/sites'; metricName = 'Http2xx'; aggregationType = 'Total'; refreshInterval = 'PT1M'; timeGrain = 'PT5M'; dataUnit = 'Count'; evaluationRules = @{ unhealthyRule = @{ operator = 'LessThan'; threshold = 1 } } }
    }
    $azureResource = @{ authenticationSetting = $authSettingName; azureResourceId = $arId; resourceHealth = @{ enabled = 'Disabled' }; signals = @($sig) }
    $what = $sig.displayName
  }
  Write-Host "==> Uptime signal ($what) on '$dn'" -ForegroundColor Cyan
  $props = @{ displayName = $dn; impact = 'Standard'; signalGroups = @{ azureResource = $azureResource } }
  if ($e.properties.icon) { $props.icon = @{ iconName = $e.properties.icon.iconName } }
  Invoke-ArmPut -Url "$mgmt$hmId/entities/$($e.name)`?api-version=$api" -Label "uptime $dn" -Body @{ properties = $props }
}

# --- Roll the topology up into the model root ------------------------------
# Discovery attaches the app entities under a parent entity named after the discovery rule, but the
# model root (named after the health model) is not linked to it by default, so the root reads
# Unknown. Add the edge so the workload health rolls up into the root.
Write-Host '==> Linking the model root to each discovery node so health rolls up' -ForegroundColor Cyan
foreach ($pe in $parentEntities) {
  Invoke-ArmPut -Url "$mgmt$hmId/relationships/root-to-$pe`?api-version=$api" -Label "root -> $pe" -Body @{
    properties = @{ parentEntityName = $HealthModelName; childEntityName = $pe }
  }
}

Write-Host ''
Write-Host '==> Done. AMW signals and alerts configured.' -ForegroundColor Green
Write-Host 'Signals evaluate every minute. With no live traffic they read "Unknown"; run the SLI'
Write-Host 'traffic generator (../../01-sli-demo/load/generate-traffic.js) to make them report a value.'
Write-Host 'Open the health model > entity > Signals / Alerts to review.'
