<#
.SYNOPSIS
  Persistently create ONE SLI via the ARM API and verify it survives.

.DESCRIPTION
  The preview SLI engine only registers the source metric's dimensions in its
  metadata bridge intermittently, and it tears an SLI down if the metric goes
  stale. This script keeps retrying the create (trying two candidate SLIs each
  round) until one is accepted, then polls it to confirm it persists. Keep the
  traffic generator running while this runs so the recording-rule metrics stay
  fresh.

.EXAMPLE
  ./create-one-sli.ps1 -RetryMinutes 90
#>
[CmdletBinding()]
param(
  [string]$ServiceGroupName = 'CheckoutSG-ioarvugvrpkmc',
  [int]$RetryMinutes = 90,
  [int]$VerifyMinutes = 4
)

$ErrorActionPreference = 'Stop'
$apiSli = '2025-03-01-preview'
$mgmt = 'https://management.azure.com'
$amwId = '/subscriptions/463a82d4-1896-4332-aeeb-618ee5a5aa93/resourceGroups/rg-sli-demo/providers/Microsoft.Monitor/accounts/slidemo-amw-ioarvugvrpkmc'
$uamiId = '/subscriptions/463a82d4-1896-4332-aeeb-618ee5a5aa93/resourceGroups/rg-sli-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/slidemo-id-ioarvugvrpkmc'

function Source($metric, $filters, $dim, $spatial = 'Sum', $temporal = 'Average') {
  @{
    signalSourceId                  = 'A'
    metricNamespace                 = 'customdefault'
    metricName                      = $metric
    sourceAmwAccountManagedIdentity = $uamiId
    sourceAmwAccountResourceId      = $amwId
    filters                         = @($filters)
    spatialAggregation              = @{ type = $spatial; dimensions = @($dim) }
    temporalAggregation             = @{ type = $temporal }
  }
}

function Body($category, $props) {
  @{
    identity   = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $uamiId = @{} } }
    properties = $props
  }
}

# Two candidate SLIs. The dependency one used the metric that succeeded manually.
$candidates = @(
  @{
    Name = 'PaymentDependencySLI'
    Body = (Body 'Availability' @{
        description            = 'Payment dependency success rate (status ok / all). Target 99.5%.'
        category               = 'Availability'
        evaluationType         = 'RequestBased'
        enableAlert            = $false
        destinationAmwAccounts = @(@{ resourceId = $amwId; identity = $uamiId })
        baselineProperties     = @{ baseline = @{ value = 99.5; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
        sliProperties          = @{
          goodSignals  = @{ signalSources = @((Source 'sli:dependency_calls:rate5m' @(@{dimensionName='dependency';operator='eq';value='payment'},@{dimensionName='status';operator='eq';value='ok'}) 'dependency')); signalFormula = 'A' }
          totalSignals = @{ signalSources = @((Source 'sli:dependency_calls:rate5m' @(@{dimensionName='dependency';operator='eq';value='payment'}) 'dependency')); signalFormula = 'A' }
        }
      })
  },
  @{
    Name = 'CheckoutAvailabilitySLI'
    Body = (Body 'Availability' @{
        description            = 'Checkout request success rate (2xx / all). Target 99.9%.'
        category               = 'Availability'
        evaluationType         = 'RequestBased'
        enableAlert            = $false
        destinationAmwAccounts = @(@{ resourceId = $amwId; identity = $uamiId })
        baselineProperties     = @{ baseline = @{ value = 99.9; evaluationPeriodDays = 7; evaluationCalculationType = 'RollingDays' } }
        sliProperties          = @{
          goodSignals  = @{ signalSources = @((Source 'sli:http_requests:rate5m' @(@{dimensionName='service';operator='eq';value='checkout'},@{dimensionName='status_class';operator='eq';value='2xx'}) 'service')); signalFormula = 'A' }
          totalSignals = @{ signalSources = @((Source 'sli:http_requests:rate5m' @(@{dimensionName='service';operator='eq';value='checkout'}) 'service')); signalFormula = 'A' }
        }
      })
  }
)

function Try-Create($cand) {
  $tmp = New-TemporaryFile
  ($cand.Body | ConvertTo-Json -Depth 20) | Set-Content -Path $tmp -Encoding utf8
  $url = "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$($cand.Name)" + "?api-version=$apiSli"
  $raw = az rest --method put --url $url --headers 'Content-Type=application/json' --body "@$tmp" 2>&1 | Out-String
  Remove-Item $tmp -ErrorAction SilentlyContinue
  return $raw
}

$deadline = (Get-Date).AddMinutes($RetryMinutes)
$round = 0
$created = $null
Write-Host "==> Persistently creating one SLI (up to $RetryMinutes min). Keep traffic running." -ForegroundColor Cyan
while ((Get-Date) -lt $deadline -and -not $created) {
  $round++
  foreach ($cand in $candidates) {
    $raw = Try-Create $cand
    if ($raw -match '"provisioningState"') {
      Write-Host ("[r{0}] {1}: ACCEPTED ({2})" -f $round, $cand.Name, ((($raw | ConvertFrom-Json).properties.provisioningState))) -ForegroundColor Green
      $created = $cand.Name
      break
    } elseif ($raw -match 'does not exist in current context') {
      Write-Host ("[r{0}] {1}: dims not registered yet" -f $round, $cand.Name)
    } else {
      $snippet = ($raw -replace '\s+', ' ')
      Write-Host ("[r{0}] {1}: other -> {2}" -f $round, $cand.Name, $snippet.Substring(0, [Math]::Min(160, $snippet.Length)))
    }
  }
  if (-not $created) { Start-Sleep -Seconds 20 }
}

if (-not $created) {
  Write-Host "==> TIMED OUT: no SLI accepted within $RetryMinutes min." -ForegroundColor Yellow
  exit 1
}

# Verify it persists (the backend can tear down an SLI whose streaming rule fails).
Write-Host "==> Verifying $created persists for $VerifyMinutes min..." -ForegroundColor Cyan
$url = "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$created" + "?api-version=$apiSli"
$vEnd = (Get-Date).AddMinutes($VerifyMinutes)
$gone = $false
while ((Get-Date) -lt $vEnd) {
  Start-Sleep -Seconds 30
  $g = az rest --method get --url $url 2>&1 | Out-String
  if ($g -match 'ResourceNotFound|could not be found') { $gone = $true; Write-Host "    torn down — resuming retries is recommended"; break }
  $state = (($g | ConvertFrom-Json).properties.provisioningState)
  $exec = (($g | ConvertFrom-Json).properties.executionState.state)
  Write-Host ("    still present: provisioning=$state exec=$exec")
}

if ($gone) {
  Write-Host "==> $created was torn down. Re-run this script (traffic must stay on)." -ForegroundColor Yellow
  exit 2
}

Write-Host ''
Write-Host "==> SUCCESS: '$created' is created and has persisted." -ForegroundColor Green
Write-Host "    Portal: Service groups -> $ServiceGroupName -> Monitor -> Monitoring -> View all SLIs"
