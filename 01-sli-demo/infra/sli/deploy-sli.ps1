<#
.SYNOPSIS
  Phase 2 of the Azure Monitor SLI/SLO demo: create the Service Group, attach the
  resource group as a member, and author the three SLIs (availability, latency,
  dependency) over the Prometheus recording-rule metrics.

.DESCRIPTION
  One-stop, idempotent orchestrator. It reads the outputs of the main App Service
  deployment (deployed by ../infra-deploy.ps1), then:

    1. Deploys the Prometheus recording rules (recording-rules.bicep). These expose
       SLI-ready dimensions; the SLI query engine cannot see labels on raw
       remote-written series, only on recording-rule output metrics.
    2. Creates the tenant-scoped Service Group under the tenant root group.
    3. Adds the demo resource group to the Service Group as a member.
    4. Waits for the recording-rule metrics to start producing data.
    5. Creates the three SLIs as extension resources on the Service Group.
    6. Polls each SLI until provisioning succeeds and prints a summary.

  Service Groups and SLIs are preview features driven through az rest because the
  Service Group is tenant-scoped and the SLI is a preview extension resource.

.EXAMPLE
  ./deploy-sli.ps1
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$MainDeploymentName = 'main',
  # Service Group name must be unique in the tenant. Defaults to the value the main
  # deployment suggested (CheckoutSG-<suffix>).
  [string]$ServiceGroupName,
  [string]$ServiceGroupDisplayName = 'Checkout Service Group (SLI demo)',
  [int]$MetricWaitMinutes = 10,
  # How long to keep retrying SLI creation while the Azure Monitor Workspace
  # registers recording-rule metric dimensions in the metrics metadata store. The
  # SLI query validator rejects dimension filters until that indexing completes.
  # Histogram-derived metrics (the latency P95) only start existing once traffic
  # flows, so their dimensions index later than the always-present counter metrics;
  # allow a longer window for them to catch up.
  [int]$SliIndexingRetryMinutes = 45,
  [switch]$SkipRecordingRules,
  # Action group notified by the SLI SLO-breach alerts (created in the RG if missing).
  [string]$ActionGroupName = 'ag-sli-demo',
  [switch]$SkipAlerts
)

$ErrorActionPreference = 'Stop'
$apiSli   = '2025-03-01-preview'
$apiSg    = '2024-02-01-preview'
$apiMember = '2023-09-01-preview'
$apiSettings = '2025-06-03-preview'
$mgmt     = 'https://management.azure.com'

function Invoke-Arm {
  param(
    [Parameter(Mandatory)][ValidateSet('get', 'put', 'post', 'delete')][string]$Method,
    [Parameter(Mandatory)][string]$Url,
    [object]$Body
  )
  $args = @('rest', '--method', $Method, '--url', $Url)
  if ($Body) {
    $tmp = New-TemporaryFile
    ($Body | ConvertTo-Json -Depth 20) | Set-Content -Path $tmp -Encoding utf8
    $args += @('--headers', 'Content-Type=application/json', '--body', "@$tmp")
  }
  $raw = az @args 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw $raw.Trim() }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return $raw | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# 0. Context + main deployment outputs
# ---------------------------------------------------------------------------
Write-Host '==> Reading deployment context' -ForegroundColor Cyan
$ctx       = az account show -o json | ConvertFrom-Json
$subId     = $ctx.id
$tenantId  = $ctx.tenantId
$rootSgId  = "/providers/Microsoft.Management/serviceGroups/$tenantId"

$out = (az deployment group show -g $ResourceGroup -n $MainDeploymentName --query properties.outputs -o json | ConvertFrom-Json)
$amwId   = $out.azureMonitorWorkspaceId.value
$uamiId  = $out.sliManagedIdentityId.value
$suffix  = $out.namingSuffix.value
$queryEp = $out.azureMonitorQueryEndpoint.value
if (-not $ServiceGroupName) { $ServiceGroupName = $out.suggestedServiceGroupName.value }

Write-Host "    Subscription : $subId"
Write-Host "    Tenant       : $tenantId"
Write-Host "    AMW          : $amwId"
Write-Host "    Identity     : $uamiId"
Write-Host "    ServiceGroup : $ServiceGroupName"

# ---------------------------------------------------------------------------
# 1. Recording rules (SLI-ready dimensions)
# ---------------------------------------------------------------------------
if (-not $SkipRecordingRules) {
  Write-Host '==> Deploying Prometheus recording rules' -ForegroundColor Cyan
  az deployment group create -g $ResourceGroup -n 'sli-recording-rules' `
    -f (Join-Path $PSScriptRoot 'recording-rules.bicep') `
    -p azureMonitorWorkspaceId=$amwId namePrefix="slidemo" `
    --query properties.provisioningState -o tsv | Out-Host
}

# ---------------------------------------------------------------------------
# 2. Service Group
# ---------------------------------------------------------------------------
Write-Host '==> Creating Service Group' -ForegroundColor Cyan
Invoke-Arm -Method put -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName`?api-version=$apiSg" -Body @{
  properties = @{ displayName = $ServiceGroupDisplayName; parent = @{ resourceId = $rootSgId } }
} | Out-Null

for ($i = 0; $i -lt 20; $i++) {
  $sg = Invoke-Arm -Method get -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName`?api-version=$apiSg"
  if ($sg.properties.provisioningState -in @('Succeeded', 'Failed')) { break }
  Start-Sleep -Seconds 6
}
Write-Host "    Service Group: $($sg.properties.provisioningState)"

# ---------------------------------------------------------------------------
# 3. Membership: add the resource group to the Service Group
# ---------------------------------------------------------------------------
Write-Host '==> Adding resource group as a Service Group member' -ForegroundColor Cyan
$memberUri = "subscriptions/$subId/resourceGroups/$ResourceGroup"
Invoke-Arm -Method put -Url "$mgmt/$memberUri/providers/Microsoft.Relationships/serviceGroupMember/$ServiceGroupName`?api-version=$apiMember" -Body @{
  properties = @{ targetId = "/providers/Microsoft.Management/serviceGroups/$ServiceGroupName"; targetTenant = $tenantId }
} | Out-Null
Write-Host '    Member relationship submitted.'

# ---------------------------------------------------------------------------
# 3b. Enable monitoring on the Service Group (default workspace + identity)
#     Required before SLIs can be authored: it tells the SLI engine which
#     Azure Monitor Workspace and managed identity to read metrics through.
# ---------------------------------------------------------------------------
Write-Host '==> Enabling monitoring on the Service Group' -ForegroundColor Cyan
Invoke-Arm -Method put -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/settings/default`?api-version=$apiSettings" -Body @{
  properties = @{ defaultAzureMonitorWorkspace = $amwId; defaultManagedIdentity = $uamiId }
} | Out-Null
Write-Host '    Default workspace and identity set.'

# ---------------------------------------------------------------------------
# 4. Wait for recording-rule metrics to produce data
#    Two gates, because the metrics behave differently:
#      - Counter rules (sli:http_requests:rate5m) emit a series immediately (even
#        value 0), so their dimensions index early.
#      - The latency P95 rule is histogram_quantile(...), which is NaN (no series
#        at all) whenever no requests land in the rolling 5m window. It only starts
#        existing once traffic flows, and its `service` dimension indexes later.
#    Gate on BOTH so we do not enter SLI creation before the P95 metric even exists.
# ---------------------------------------------------------------------------
if (-not $SkipRecordingRules) {
  Write-Host "==> Waiting up to $MetricWaitMinutes min for recording-rule metrics" -ForegroundColor Cyan
  $token = az account get-access-token --resource 'https://prometheus.monitor.azure.com' --query accessToken -o tsv
  $deadline = (Get-Date).AddMinutes($MetricWaitMinutes)
  $counterReady = $false
  $latencyReady = $false
  function Test-PromValue {
    param([string]$Query)
    try {
      $q = Invoke-RestMethod -Uri "$queryEp/api/v1/query?query=$([uri]::EscapeDataString($Query))" -Headers @{ Authorization = "Bearer $token" }
      if ($q.data.result.Count -eq 0) { return $false }
      # Reject all-NaN results (histogram_quantile with no traffic in the window).
      foreach ($r in $q.data.result) { if ($r.value[1] -ne 'NaN') { return $true } }
      return $false
    } catch { return $false }
  }
  while ((Get-Date) -lt $deadline) {
    if (-not $counterReady) { $counterReady = Test-PromValue 'sli:http_requests:rate5m' }
    # Require the counter-based latency total to be present, which proves the login
    # path has live traffic feeding the request-based latency SLI.
    if (-not $latencyReady) { $latencyReady = Test-PromValue 'sli:http_request_latency_total:rate5m' }
    if ($counterReady -and $latencyReady) { break }
    Start-Sleep -Seconds 20
  }
  Write-Host ("    Counter metric present: {0}" -f $counterReady)
  Write-Host ("    Latency total metric present: {0}" -f $latencyReady)
  if (-not $latencyReady) {
    Write-Host '    WARNING: the latency metric is still empty. That means no login traffic is' -ForegroundColor Yellow
    Write-Host '             landing in the rolling 5-minute window, so LoginLatencySLI cannot be created.' -ForegroundColor Yellow
    Write-Host '             Start the traffic generator (load/generate-traffic.js) and keep it running,' -ForegroundColor Yellow
    Write-Host '             then re-run this script (it is idempotent).' -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------------------
# 5. SLIs
# ---------------------------------------------------------------------------
function New-SignalSource {
  param([string]$Id, [string]$Metric, [hashtable[]]$Filters, [string[]]$Dimensions, [string]$Spatial = 'Sum', [string]$Temporal = 'Average')
  @{
    signalSourceId                  = $Id
    metricNamespace                 = 'customdefault'
    metricName                      = $Metric
    sourceAmwAccountManagedIdentity = $uamiId
    sourceAmwAccountResourceId      = $amwId
    filters                         = @($Filters)
    spatialAggregation              = @{ type = $Spatial; dimensions = $Dimensions }
    temporalAggregation             = @{ type = $Temporal }
  }
}

# Window-based SLIs require windowSizeMinutes on the temporal aggregation.
function New-WindowSignalSource {
  param([string]$Id, [string]$Metric, [hashtable[]]$Filters, [string[]]$Dimensions, [string]$Spatial = 'Average', [string]$Temporal = 'Average', [int]$WindowSizeMinutes = 5)
  @{
    signalSourceId                  = $Id
    metricNamespace                 = 'customdefault'
    metricName                      = $Metric
    sourceAmwAccountManagedIdentity = $uamiId
    sourceAmwAccountResourceId      = $amwId
    filters                         = @($Filters)
    spatialAggregation              = @{ type = $Spatial; dimensions = $Dimensions }
    temporalAggregation             = @{ type = $Temporal; windowSizeMinutes = $WindowSizeMinutes }
  }
}

function Submit-Sli {
  # Attempts a single PUT. Returns a result object with:
  #   Status  = 'created' | 'pending' (dimensions not indexed yet / transient blip)
  #   Message = the raw error text (for pending), so the caller can surface it.
  # Throws only on a genuine, non-retryable error.
  param([string]$Name, [hashtable]$Properties)
  $body = @{
    identity   = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $uamiId = @{} } }
    properties = $Properties
  }
  $url = "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$Name" + "?api-version=$apiSli"
  try {
    Invoke-Arm -Method put -Url $url -Body $body | Out-Null
    return [pscustomobject]@{ Status = 'created'; Message = $null }
  } catch {
    $msg = "$_"
    if ($msg -match 'does not exist in current context|BadGateway|Bad Gateway|ServiceUnavailable|GatewayTimeout|TooManyRequests|429|temporarily|timed out|connectivity issue') {
      return [pscustomobject]@{ Status = 'pending'; Message = $msg }
    }
    throw
  }
}

$destination = @(@{ resourceId = $amwId; identity = $uamiId })

# Each SLI references a different recording-rule metric, and the workspace indexes
# each metric's dimensions independently. So we attempt every SLI each round and
# create whichever are ready, rather than blocking on one that is still indexing.
$sliSpecs = @(
  @{
    Name       = 'CheckoutAvailabilitySLI'
    Properties = @{
      description            = 'Checkout request success rate: HTTP 2xx responses divided by all checkout requests. Target 99.5%.'
      category               = 'Availability'
      evaluationType         = 'RequestBased'
      enableAlert            = $true
      destinationAmwAccounts = $destination
      baselineProperties     = @{ baseline = @{ value = 99.5; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
      sliProperties          = @{
        goodSignals  = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_requests:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'checkout' }, @{ dimensionName = 'status_class'; operator = 'eq'; value = '2xx' })); signalFormula = 'A' }
        totalSignals = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_requests:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'checkout' })); signalFormula = 'A' }
      }
    }
  },
  @{
    Name       = 'LoginLatencySLI'
    Properties = @{
      description            = 'Login latency objective: proportion of login requests completing within 300 ms (good = requests at or under 0.3s, total = all login requests). Target 99.5%.'
      category               = 'Latency'
      evaluationType         = 'RequestBased'
      enableAlert            = $true
      destinationAmwAccounts = $destination
      baselineProperties     = @{ baseline = @{ value = 99.5; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
      sliProperties          = @{
        goodSignals  = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_request_latency_good:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'login' })); signalFormula = 'A' }
        totalSignals = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_request_latency_total:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'login' })); signalFormula = 'A' }
      }
    }
  },
  @{
    Name       = 'PaymentDependencySLI'
    Properties = @{
      description            = 'Payment dependency success rate: successful payment calls divided by all payment calls. Target 99.5%.'
      category               = 'Availability'
      evaluationType         = 'RequestBased'
      enableAlert            = $true
      destinationAmwAccounts = $destination
      baselineProperties     = @{ baseline = @{ value = 99.5; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
      sliProperties          = @{
        goodSignals  = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:dependency_calls:rate5m' -Dimensions @('dependency') -Filters @{ dimensionName = 'dependency'; operator = 'eq'; value = 'payment' }, @{ dimensionName = 'status'; operator = 'eq'; value = 'ok' })); signalFormula = 'A' }
        totalSignals = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:dependency_calls:rate5m' -Dimensions @('dependency') -Filters @{ dimensionName = 'dependency'; operator = 'eq'; value = 'payment' })); signalFormula = 'A' }
      }
    }
  }
)

Write-Host '==> Creating SLIs' -ForegroundColor Cyan
$pending = [System.Collections.ArrayList]@($sliSpecs)
$deadline = (Get-Date).AddMinutes($SliIndexingRetryMinutes)
$firstError = @{}   # print each SLI's underlying error once, so it is not masked.
while ($pending.Count -gt 0) {
  $done = @()
  foreach ($spec in $pending) {
    $result = Submit-Sli -Name $spec.Name -Properties $spec.Properties
    if ($result.Status -eq 'created') {
      Write-Host "    $($spec.Name) created" -ForegroundColor Green
      $done += $spec
    } else {
      Write-Host "    $($spec.Name) waiting for metric-dimension indexing..."
      if (-not $firstError.ContainsKey($spec.Name) -and $result.Message) {
        $firstError[$spec.Name] = $true
        # Trim to the meaningful part of the validator error.
        $detail = $result.Message
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) + '...' }
        Write-Host "      (validator: $detail)" -ForegroundColor DarkGray
      }
    }
  }
  foreach ($d in $done) { $pending.Remove($d) }
  if ($pending.Count -eq 0) { break }
  if ((Get-Date) -ge $deadline) {
    Write-Host "    Timed out waiting for: $($pending.Name -join ', '). Keep traffic running and re-run the script to finish (idempotent)." -ForegroundColor Yellow
    break
  }
  Start-Sleep -Seconds 30
}


# ---------------------------------------------------------------------------
# 6. Poll + summary
# ---------------------------------------------------------------------------
Write-Host '==> Verifying SLI provisioning' -ForegroundColor Cyan
$sliNames = @('CheckoutAvailabilitySLI', 'LoginLatencySLI', 'PaymentDependencySLI')
foreach ($name in $sliNames) {
  $state = '?'
  for ($i = 0; $i -lt 20; $i++) {
    $url = "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$name" + "?api-version=$apiSli"
    $sli = Invoke-Arm -Method get -Url $url
    $state = $sli.properties.provisioningState
    if ($state -in @('Succeeded', 'Failed', 'Canceled')) { break }
    Start-Sleep -Seconds 6
  }
  '{0,-26} {1}' -f $name, $state | Write-Host
}

# ---------------------------------------------------------------------------
# 7. SLI alerts (portal-equivalent LINKED metric alerts)
#    The SLI resource has no alert-config property (enableAlert is only a flag), so
#    the portal's "Enable Alert" instead creates Microsoft.Insights/metricAlerts with
#    PromQLCriteria over the SLI's own good/total metrics, tagged with
#    customProperties.sliId. That sliId tag is what makes them show as LINKED on the
#    SLI blade. We reproduce that exactly: baseline + fast burn + slow burn per SLI,
#    wired to the action group. NOTE: these are DISPLAY-ONLY on the SLI blade - their
#    PromQL selector does not resolve at evaluation time, so they do not actually fire.
#    The SRE Agent trigger is the sli-fast-alerts Prometheus rule created by
#    ../../03-sre-agent/sli-alert-scenario.ps1 (verified end-to-end).
# ---------------------------------------------------------------------------
if (-not $SkipAlerts) {
  Write-Host '==> Creating SLI linked alerts (baseline + fast/slow burn metric alerts)' -ForegroundColor Cyan
  $agId = az monitor action-group show -g $ResourceGroup -n $ActionGroupName --query id -o tsv 2>$null
  if (-not $agId) {
    Write-Host "    Action group '$ActionGroupName' not found; creating it."
    az monitor action-group create -g $ResourceGroup -n $ActionGroupName --short-name sliDemo -o none
    $agId = az monitor action-group show -g $ResourceGroup -n $ActionGroupName --query id -o tsv
  }
  $amwLoc = az resource show --ids $amwId --query location -o tsv
  $maApi = '2024-03-01-preview'
  $sgResId = "/providers/Microsoft.Management/serviceGroups/$ServiceGroupName"
  $noDim = 'sum without ("INCLUDE-ALL-DIMENSIONS-DONT-REMOVE")'

  function New-SliLinkedAlert {
    param([string]$SliName, [double]$Target, [int]$BaselineSeverity)
    $sliResId = "$sgResId/providers/Microsoft.Monitor/slis/$SliName"
    $good = "{`"${SliName}:good`"}"
    $total = "{`"${SliName}:total`"}"
    $budget = (1 - ($Target / 100))
    $alerts = @(
      @{ suffix = 'baseline alert'; sev = $BaselineSeverity; waitFor = 'PT1M';
        query = "($noDim ($good) / $noDim ($total)) * 100 < $Target";
        cp = @{ alertKind = 'baseline' } },
      @{ suffix = 'fast burn alert'; sev = 2; waitFor = 'PT5M';
        query = "(($noDim (sum_over_time(${total}[1h])) - $noDim (sum_over_time(${good}[1h]))) / ($noDim (sum_over_time(${total}[1h])) * $budget)) > 14";
        cp = @{ alertKind = 'fast-burn-rate'; burnRate = '14'; lookbackHours = '1' } },
      @{ suffix = 'slow burn alert'; sev = 3; waitFor = 'PT5M';
        query = "(($noDim (sum_over_time(${total}[6h])) - $noDim (sum_over_time(${good}[6h]))) / ($noDim (sum_over_time(${total}[6h])) * $budget)) > 6";
        cp = @{ alertKind = 'slow-burn-rate'; burnRate = '6'; lookbackHours = '6' } }
    )
    foreach ($a in $alerts) {
      $name = "$SliName $($a.suffix)"
      $cp = $a.cp.Clone(); $cp.serviceGroupId = $sgResId; $cp.sliId = $sliResId
      $body = @{
        location   = $amwLoc
        identity   = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $uamiId = @{} } }
        properties = @{
          severity            = $a.sev
          enabled             = $true
          scopes              = @($amwId)
          targetResourceType  = 'microsoft.monitor/accounts'
          evaluationFrequency = 'PT1M'
          criteria            = @{
            'odata.type'   = 'Microsoft.Azure.Monitor.PromQLCriteria'
            allOf          = @(@{ criterionType = 'StaticThresholdCriterion'; name = 'SliAlertCriterion'; query = $a.query })
            failingPeriods = @{ 'for' = $a.waitFor }
          }
          resolveConfiguration = @{ autoResolved = $true; timeToResolve = 'PT5M' }
          actions              = @(@{ actionGroupId = $agId })
          customProperties     = $cp
          description          = "SLI $($a.cp.alertKind) alert for $SliName."
        }
      }
      $enc = [uri]::EscapeDataString($name)
      $url = "$mgmt/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/metricAlerts/$enc`?api-version=$maApi"
      # Delete any pre-existing alert first (a portal-created one may sit in a different
      # location, and a metric alert's location cannot be changed in place).
      az rest --method delete --url $url -o none 2>$null
      Invoke-Arm -Method put -Url $url -Body $body | Out-Null
      Write-Host "    $name  (Sev$($a.sev))" -ForegroundColor Green
    }
  }

  New-SliLinkedAlert -SliName 'CheckoutAvailabilitySLI' -Target 99.5 -BaselineSeverity 1
  New-SliLinkedAlert -SliName 'LoginLatencySLI' -Target 99.5 -BaselineSeverity 2
  New-SliLinkedAlert -SliName 'PaymentDependencySLI' -Target 99.5 -BaselineSeverity 2
  # Retire interim standalone Prometheus rule groups (superseded by the linked metric alerts).
  foreach ($legacy in @('sli-fast-alerts', 'sli-slo-alerts')) {
    az rest --method delete --url "$mgmt/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.AlertsManagement/prometheusRuleGroups/$legacy`?api-version=2023-03-01" -o none 2>$null
  }
}

Write-Host ''
Write-Host 'Done. View the Service Group and SLIs in the Azure portal:' -ForegroundColor Green
Write-Host "  Service Group: $ServiceGroupName"
Write-Host '  Portal: https://portal.azure.com  ->  Service Groups  ->  ' -NoNewline; Write-Host $ServiceGroupName
