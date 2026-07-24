<#
.SYNOPSIS
  Latency relief: scale the App Service plan out (more instances) or up (larger SKU).

.DESCRIPTION
  Use when LoginLatencySLI degrades due to load rather than injected chaos. Scaling out adds instances;
  scaling up changes the SKU tier. Both are reversible.

.EXAMPLE
  ./scale-plan.ps1 -Instances 3
  ./scale-plan.ps1 -Sku P1v3
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$PlanName,
  [int]$Instances,
  [string]$Sku
)

$ErrorActionPreference = 'Stop'

if (-not $PlanName) {
  $PlanName = az appservice plan list -g $SliResourceGroup --query "[0].name" -o tsv 2>$null
  if (-not $PlanName) { throw "App Service plan not found in '$SliResourceGroup'. Pass -PlanName explicitly." }
}
Write-Host "==> App Service plan: $PlanName" -ForegroundColor Cyan

if ($Sku) {
  Write-Host "==> Scaling up to SKU '$Sku'" -ForegroundColor Cyan
  az appservice plan update -g $SliResourceGroup -n $PlanName --sku $Sku -o none
  Write-Host "    SKU set to $Sku" -ForegroundColor Green
}
if ($Instances) {
  Write-Host "==> Scaling out to $Instances instance(s)" -ForegroundColor Cyan
  az appservice plan update -g $SliResourceGroup -n $PlanName --number-of-workers $Instances -o none
  Write-Host "    instance count set to $Instances" -ForegroundColor Green
}
if (-not $Sku -and -not $Instances) {
  Write-Host '    Nothing to do. Pass -Instances <n> to scale out or -Sku <sku> to scale up.' -ForegroundColor Yellow
}
