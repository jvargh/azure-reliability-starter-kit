<#
.SYNOPSIS
  Drives steady traffic against all three SLI paths at once: checkout, login, and
  the payment dependency (exercised inside the checkout flow). Keeps the SLI source
  metrics emitting continuously so evaluation windows never go all-NaN.

.DESCRIPTION
  Sends a weighted mix of GET /api/checkout and GET /api/login to the frontend at a
  target rate. Payment traffic is produced automatically because the backend calls
  the payment dependency during checkout. Prints a live counter per path.

  Requires PowerShell 7+ (uses ForEach-Object -Parallel).

.PARAMETER Target
  Frontend base URL. Optional. When omitted, it is discovered automatically from the
  resource group (the 'main' deployment's frontendUrl output, or the App Service whose
  name contains '-fe-'). Requires Azure CLI signed in.

.PARAMETER ResourceGroup
  Resource group used to auto-discover the frontend URL when -Target is not given.

.PARAMETER MainDeploymentName
  Name of the main deployment to read the frontendUrl output from (default 'main').

.PARAMETER Rps
  Approximate total requests per second across all paths.

.PARAMETER DurationSeconds
  How long to run. Use 0 to run until you press Ctrl+C.

.PARAMETER CheckoutWeight
  Fraction of requests sent to /api/checkout (the rest go to /api/login).

.EXAMPLE
  ./generate-traffic-all.ps1 -Rps 30

.EXAMPLE
  ./generate-traffic-all.ps1 -Rps 40 -DurationSeconds 28800 -CheckoutWeight 0.6

.EXAMPLE
  ./generate-traffic-all.ps1 -ResourceGroup rg-sli-demo -Rps 30 -DurationSeconds 1800
#>
[CmdletBinding()]
param(
  [string]$Target,
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$MainDeploymentName = 'main',
  [int]$Rps = 30,
  [int]$DurationSeconds = 0,
  [double]$CheckoutWeight = 0.7
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'This script needs PowerShell 7+ (pwsh). Run it with: pwsh -File generate-traffic-all.ps1'
}

# Resolve the frontend URL automatically when it was not passed in, so callers do not have to
# know the generated resource name. Prefer the deployment output; fall back to the App Service
# in the resource group whose name contains '-fe-'. Requires Azure CLI signed in.
if (-not $Target) {
  $Target = az deployment group show -g $ResourceGroup -n $MainDeploymentName --query 'properties.outputs.frontendUrl.value' -o tsv 2>$null
  if (-not $Target) {
    $feHost = az webapp list -g $ResourceGroup --query "[?contains(name,'-fe-')].defaultHostName | [0]" -o tsv 2>$null
    if ($feHost) { $Target = "https://$feHost" }
  }
  if (-not $Target) {
    throw "Could not resolve the frontend URL from resource group '$ResourceGroup'. Pass -Target explicitly or check 'az login'."
  }
  $Target = $Target.TrimEnd('/')
  Write-Host "Resolved target from '$ResourceGroup': $Target" -ForegroundColor DarkGray
}

$checkout = "$Target/api/checkout"
$login    = "$Target/api/login"
$endTime  = if ($DurationSeconds -gt 0) { (Get-Date).AddSeconds($DurationSeconds) } else { [datetime]::MaxValue }

# Shared, thread-safe counters for the parallel workers.
$counts = [hashtable]::Synchronized(@{ checkout = 0; login = 0; okC = 0; okL = 0; failC = 0; failL = 0 })

Write-Host "Driving ~$Rps rps against $Target" -ForegroundColor Cyan
Write-Host ("  checkout {0:P0} (also drives payment dependency) | login {1:P0}" -f $CheckoutWeight, (1 - $CheckoutWeight))
if ($DurationSeconds -gt 0) { Write-Host "  duration: $DurationSeconds s" } else { Write-Host '  duration: until Ctrl+C' }
Write-Host ''

$start = Get-Date
while ((Get-Date) -lt $endTime) {
  1..$Rps | ForEach-Object -Parallel {
    $c = $using:counts
    $isCheckout = (Get-Random -Minimum 0.0 -Maximum 1.0) -le $using:CheckoutWeight
    $url = if ($isCheckout) { $using:checkout } else { $using:login }
    $okField = if ($isCheckout) { 'okC' } else { 'okL' }
    $failField = if ($isCheckout) { 'failC' } else { 'failL' }
    $pathField = if ($isCheckout) { 'checkout' } else { 'login' }
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 10
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $c[$okField]++ } else { $c[$failField]++ }
    } catch {
      $c[$failField]++
    }
    $c[$pathField]++
  } -ThrottleLimit ([Math]::Max(10, $Rps))

  $elapsed = [int]((Get-Date) - $start).TotalSeconds
  Write-Host ("`r[{0}s] checkout: sent={1} ok={2} fail={3} | login: sent={4} ok={5} fail={6} | payment via checkout   " -f `
      $elapsed, $counts.checkout, $counts.okC, $counts.failC, $counts.login, $counts.okL, $counts.failL) -NoNewline
  Start-Sleep -Seconds 1
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
