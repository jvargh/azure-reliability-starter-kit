<#
.SYNOPSIS
  Primary safe remediation: reset the backend chaos knobs (errorRate + extraLatencyMs) to zero.

.DESCRIPTION
  The Checkout/Login backend exposes POST /admin/chaos to tune failure rate and latency per service.
  Injected degradation is the most common cause of a demo SLI breach, so resetting it is the first,
  least-disruptive fix. Idempotent and reversible.

.EXAMPLE
  ./disable-chaos.ps1
  ./disable-chaos.ps1 -BackendUrl https://slidemo-be-xxxx.azurewebsites.net
  ./disable-chaos.ps1 -Services checkout
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$BackendUrl,
  [string[]]$Services = @('checkout', 'login', 'payment')
)

$ErrorActionPreference = 'Stop'

if (-not $BackendUrl) {
  $beHost = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].defaultHostName | [0]" -o tsv 2>$null
  if (-not $beHost) { throw "Backend App Service not found in '$SliResourceGroup'. Pass -BackendUrl explicitly." }
  $BackendUrl = "https://$beHost"
}

Write-Host "==> Resetting chaos on $BackendUrl" -ForegroundColor Cyan
foreach ($svc in $Services) {
  $body = @{ service = $svc; errorRate = 0; extraLatencyMs = 0 } | ConvertTo-Json
  try {
    Invoke-RestMethod -Method Post "$BackendUrl/admin/chaos" -Body $body -ContentType 'application/json' | Out-Null
    Write-Host "    $svc reset (errorRate=0, extraLatencyMs=0)" -ForegroundColor Green
  }
  catch {
    Write-Host "    $svc reset failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
Write-Host '==> Done. With traffic flowing, burn rate falls below 1 and the SLI recovers within a few evaluation cycles.' -ForegroundColor Green
