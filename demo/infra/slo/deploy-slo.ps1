<#
.SYNOPSIS
  Phase 2 of the Azure Monitor SLI/SLO demo: create the Service Group, attach the
  resource group as a member, and author the three SLIs (availability, latency,
  dependency) over the Prometheus recording-rule metrics.

.DESCRIPTION
  One-stop, idempotent orchestrator. It reads the outputs of the main App Service
  deployment (deployed by ../deploy.ps1), then:

    1. Deploys the Prometheus recording rules (recording-rules.bicep). These expose
       SLI-ready dimensions; the SLI query engine cannot see labels on raw
       remote-written series, only on recording-rule output metrics.
    2. Creates the tenant-scoped Service Group under the tenant root group.
    3. Adds the demo resource group to the Service Group as a member.
    4. Waits for the recording-rule metrics to start producing data.
    5. Creates the three SLIs as extension resources on the Service Group.
    6. Polls each SLI until provisioning succeeds and prints a summary.

  Service Groups and SLIs are preview features driven through az rest because the
  Service Group is tenant-scoped and the SLI is a preview extension resource. A
  declarative equivalent is in servicegroup-sli.bicep.

.EXAMPLE
  ./deploy-slo.ps1
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
  [int]$SliIndexingRetryMinutes = 25,
  [switch]$SkipRecordingRules
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
# ---------------------------------------------------------------------------
if (-not $SkipRecordingRules) {
  Write-Host "==> Waiting up to $MetricWaitMinutes min for recording-rule metrics" -ForegroundColor Cyan
  $token = az account get-access-token --resource 'https://prometheus.monitor.azure.com' --query accessToken -o tsv
  $deadline = (Get-Date).AddMinutes($MetricWaitMinutes)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $q = Invoke-RestMethod -Uri "$queryEp/api/v1/query?query=sli:http_requests:rate5m" -Headers @{ Authorization = "Bearer $token" }
      if ($q.data.result.Count -gt 0) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 20
  }
  Write-Host ("    Recording-rule metric present: {0}" -f $ready)
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
  # Attempts a single PUT. Returns 'created', 'pending' (metric dimensions not
  # indexed yet / transient blip), or throws on a genuine error.
  param([string]$Name, [hashtable]$Properties)
  $body = @{
    identity   = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $uamiId = @{} } }
    properties = $Properties
  }
  $url = "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$Name" + "?api-version=$apiSli"
  try {
    Invoke-Arm -Method put -Url $url -Body $body | Out-Null
    return 'created'
  } catch {
    $msg = "$_"
    if ($msg -match 'does not exist in current context|BadGateway|Bad Gateway|ServiceUnavailable|GatewayTimeout|TooManyRequests|429|temporarily|timed out|connectivity issue') {
      return 'pending'
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
      description            = 'Checkout request success rate: HTTP 2xx responses divided by all checkout requests. Target 99.9%.'
      category               = 'Availability'
      evaluationType         = 'RequestBased'
      enableAlert            = $true
      destinationAmwAccounts = $destination
      baselineProperties     = @{ baseline = @{ value = 99.9; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
      sliProperties          = @{
        goodSignals  = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_requests:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'checkout' }, @{ dimensionName = 'status_class'; operator = 'eq'; value = '2xx' })); signalFormula = 'A' }
        totalSignals = @{ signalSources = @((New-SignalSource -Id 'A' -Metric 'sli:http_requests:rate5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'checkout' })); signalFormula = 'A' }
      }
    }
  },
  @{
    Name       = 'LoginLatencySLI'
    Properties = @{
      description            = 'Login P95 latency under 300 ms. Each window counts as good when the P95 latency is at or below 0.3 seconds. Target 99% of windows.'
      category               = 'Latency'
      evaluationType         = 'WindowBased'
      enableAlert            = $true
      destinationAmwAccounts = $destination
      baselineProperties     = @{ baseline = @{ value = 99; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
      sliProperties          = @{
        windowUptimeCriteria = @{ target = 0.3; comparator = 'lte' }
        signals              = @{ signalSources = @((New-WindowSignalSource -Id 'A' -Metric 'sli:http_request_latency_p95:5m' -Dimensions @('service') -Filters @{ dimensionName = 'service'; operator = 'eq'; value = 'login' } -Spatial 'Average' -WindowSizeMinutes 5)); signalFormula = 'A' }
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
while ($pending.Count -gt 0) {
  $done = @()
  foreach ($spec in $pending) {
    $result = Submit-Sli -Name $spec.Name -Properties $spec.Properties
    if ($result -eq 'created') {
      Write-Host "    $($spec.Name) created" -ForegroundColor Green
      $done += $spec
    } else {
      Write-Host "    $($spec.Name) waiting for metric-dimension indexing..."
    }
  }
  foreach ($d in $done) { $pending.Remove($d) }
  if ($pending.Count -eq 0) { break }
  if ((Get-Date) -ge $deadline) {
    Write-Host "    Timed out waiting for: $($pending.Name -join ', '). Re-run the script to finish (idempotent)." -ForegroundColor Yellow
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

Write-Host ''
Write-Host 'Done. View the Service Group and SLIs in the Azure portal:' -ForegroundColor Green
Write-Host "  Service Group: $ServiceGroupName"
Write-Host '  Portal: https://portal.azure.com  ->  Service Groups  ->  ' -NoNewline; Write-Host $ServiceGroupName
