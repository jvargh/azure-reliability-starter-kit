# infra-validate-lab.ps1
# Post-deploy smoke test for the Azure Monitor SLI/SLO demo. Reads the outputs of the
# main deployment (created by infra-deploy.ps1) and runs a battery of checks to confirm
# the infrastructure is up and the apps are serving traffic. Prints [PASS]/[FAIL]/[SKIP]
# per check and exits non-zero if any check fails (so it can gate CI or a demo run).
#
# Usage:
#   ./infra-validate-lab.ps1 -ResourceGroup rg-sli-demo
#   ./infra-validate-lab.ps1 -ResourceGroup rg-sli-demo -IncludeMetrics          # also verify metrics reached the workspace
#   ./infra-validate-lab.ps1 -ResourceGroup rg-sli-demo -IncludeMetrics -IncludeSlo   # also verify recording rules + SLIs
#
# -IncludeMetrics / -IncludeSlo need live traffic and (for SLO) deploy-sli.ps1 to have run.

[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$MainDeploymentName = 'main',
  [string]$NamePrefix = 'slidemo',
  [switch]$IncludeMetrics,
  [switch]$IncludeSlo
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0

function Record([ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status, [string]$Name, [string]$Detail = '') {
  switch ($Status) {
    'PASS' { $script:Pass++; $color = 'Green' }
    'FAIL' { $script:Fail++; $color = 'Red' }
    'SKIP' { $script:Skip++; $color = 'DarkYellow' }
  }
  $line = if ($Detail) { "[$Status] $Name  ($Detail)" } else { "[$Status] $Name" }
  Write-Host $line -ForegroundColor $color
}

function Section([string]$Title) { Write-Host ""; Write-Host "== $Title ==" -ForegroundColor Cyan }

# Single HTTP attempt. Returns the status code (0 on transport failure) without throwing.
function Invoke-Http {
  param([string]$Url, [string]$Method = 'GET', $Body, [int]$TimeoutSec = 25)
  try {
    $p = @{ Uri = $Url; Method = $Method; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    return [int]$r.StatusCode
  }
  catch { return 0 }
}

# HTTP check with cold-start tolerance: retries a few times if the status is not the expected one.
function Test-Endpoint {
  param([string]$Name, [string]$Url, [int]$Expect = 200, [string]$Method = 'GET', $Body, [int]$Retries = 5)
  $status = 0
  for ($i = 1; $i -le $Retries; $i++) {
    $status = Invoke-Http -Url $Url -Method $Method -Body $Body
    if ($status -eq $Expect) { Record PASS $Name "$Method -> $status"; return }
    if ($i -lt $Retries) { Start-Sleep -Seconds 5 }
  }
  Record FAIL $Name "$Method $Url -> $status (expected $Expect)"
}

Write-Host "Validating SLI/SLO demo infrastructure in '$ResourceGroup'..." -ForegroundColor Cyan

# --- Prerequisites -----------------------------------------------------------
Section 'Prerequisites'
$account = az account show -o json 2>$null | ConvertFrom-Json
if ($account) { Record PASS 'Azure CLI signed in' $account.name } else { Record FAIL 'Azure CLI signed in' 'run: az login'; Write-Host "`nCannot continue without an authenticated session." -ForegroundColor Red; exit 1 }

$rgExists = (az group exists -n $ResourceGroup 2>$null) -eq 'true'
if ($rgExists) { Record PASS "Resource group '$ResourceGroup' exists" } else { Record FAIL "Resource group '$ResourceGroup' exists"; Write-Host "`nResource group not found; nothing to validate." -ForegroundColor Red; exit 1 }

# --- Deployment + outputs ----------------------------------------------------
Section 'Deployment'
$dep = az deployment group show -g $ResourceGroup -n $MainDeploymentName -o json 2>$null | ConvertFrom-Json
if (-not $dep) { Record FAIL "Deployment '$MainDeploymentName' found"; Write-Host "`nMain deployment not found; run infra-deploy.ps1 first." -ForegroundColor Red; exit 1 }
Record PASS "Deployment '$MainDeploymentName' found"
if ($dep.properties.provisioningState -eq 'Succeeded') { Record PASS 'Deployment provisioningState' 'Succeeded' } else { Record FAIL 'Deployment provisioningState' $dep.properties.provisioningState }

$o = $dep.properties.outputs
$feUrl = $o.frontendUrl.value
$beUrl = $o.backendUrl.value
$pxUrl = $o.proxyUrl.value
$apps = [ordered]@{
  frontend  = $o.frontendName.value
  backend   = $o.backendName.value
  proxy     = $o.proxyName.value
  collector = $o.collectorName.value
}

# --- App Service state -------------------------------------------------------
Section 'App Service state'
foreach ($role in $apps.Keys) {
  $name = $apps[$role]
  $state = az webapp show -g $ResourceGroup -n $name --query state -o tsv 2>$null
  if ($state -eq 'Running') { Record PASS "$role app running" $name }
  else {
    $shown = if ([string]::IsNullOrEmpty($state)) { 'not found' } else { $state }
    Record FAIL "$role app running" "$name state=$shown"
  }
}

# --- Health endpoints --------------------------------------------------------
Section 'Health endpoints'
Test-Endpoint 'backend /healthz'  "$beUrl/healthz"
Test-Endpoint 'frontend /healthz' "$feUrl/healthz"
Test-Endpoint 'proxy /healthz'    "$pxUrl/healthz"
Test-Endpoint 'frontend home'     "$feUrl/"

# --- Functional endpoints (also seeds a little traffic) ----------------------
Section 'Functional endpoints'
Test-Endpoint 'backend /login'        "$beUrl/login"
Test-Endpoint 'backend /checkout'     "$beUrl/checkout"
Test-Endpoint 'frontend /api/login'   "$feUrl/api/login"       # exercises frontend -> backend proxy
Test-Endpoint 'frontend /api/checkout' "$feUrl/api/checkout"

# --- Supporting resources ----------------------------------------------------
Section 'Supporting resources'
$idId = $o.sliManagedIdentityId.value
if ($idId) { az resource show --ids $idId -o none 2>$null }
if ($idId -and $LASTEXITCODE -eq 0) { Record PASS 'Managed identity exists' $o.sliManagedIdentityClientId.value }
else { Record FAIL 'Managed identity exists' }

$amwId = $o.azureMonitorWorkspaceId.value
if ($amwId) { az resource show --ids $amwId -o none 2>$null }
if ($amwId -and $LASTEXITCODE -eq 0) { Record PASS 'Azure Monitor Workspace exists' $o.azureMonitorWorkspaceName.value }
else { Record FAIL 'Azure Monitor Workspace exists' }

# --- Optional: end-to-end metric pipeline ------------------------------------
function Get-PromToken { az account get-access-token --resource 'https://prometheus.monitor.azure.com' --query accessToken -o tsv 2>$null }
function Invoke-Prom([string]$Endpoint, [string]$Query, [string]$Token) {
  try { return Invoke-RestMethod -Uri "$Endpoint/api/v1/query?query=$([uri]::EscapeDataString($Query))" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 30 }
  catch { return $null }
}

if ($IncludeMetrics -or $IncludeSlo) {
  Section 'Metric pipeline'
  $qe = $o.azureMonitorQueryEndpoint.value
  $token = Get-PromToken
  if (-not $token) { Record FAIL 'Prometheus query token acquired' 'az account get-access-token failed' }
  else {
    Record PASS 'Prometheus query token acquired'

    if ($IncludeMetrics) {
      $r = Invoke-Prom $qe 'count(http_server_requests_total)' $token
      if ($r -and $r.status -eq 'success' -and $r.data.result.Count -gt 0) { Record PASS 'Source metrics present' "http_server_requests_total series=$($r.data.result[0].value[1])" }
      elseif ($r -and $r.status -eq 'success') { Record SKIP 'Source metrics present' 'no series yet - generate traffic and re-run' }
      else { Record FAIL 'Source metrics present' 'query failed' }
    }

    if ($IncludeSlo) {
      # Recording-rule group deployed by deploy-sli.ps1
      az resource show -g $ResourceGroup -n "$NamePrefix-sli-recording-rules" --resource-type 'Microsoft.AlertsManagement/prometheusRuleGroups' -o none 2>$null
      if ($LASTEXITCODE -eq 0) { Record PASS 'Recording-rule group deployed' "$NamePrefix-sli-recording-rules" }
      else { Record FAIL 'Recording-rule group deployed' 'run deploy-sli.ps1' }

      $rr = Invoke-Prom $qe 'count(sli:http_requests:rate5m)' $token
      if ($rr -and $rr.status -eq 'success' -and $rr.data.result.Count -gt 0) { Record PASS 'Recording-rule metrics present' 'sli:http_requests:rate5m' }
      elseif ($rr -and $rr.status -eq 'success') { Record SKIP 'Recording-rule metrics present' 'no series yet - rules need ~5 min of traffic' }
      else { Record FAIL 'Recording-rule metrics present' 'query failed' }
    }
  }
}

# --- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail -gt 0) { 'Red' } else { 'Green' })
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
