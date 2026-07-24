<#
.SYNOPSIS
  Restart the backend App Service (clears transient state; use when chaos reset does not apply).

.EXAMPLE
  ./restart-backend.ps1
  ./restart-backend.ps1 -AppName slidemo-be-xxxx
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$AppName
)

$ErrorActionPreference = 'Stop'

if (-not $AppName) {
  $AppName = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].name | [0]" -o tsv 2>$null
  if (-not $AppName) { throw "Backend App Service not found in '$SliResourceGroup'. Pass -AppName explicitly." }
}

Write-Host "==> Restarting App Service '$AppName' in '$SliResourceGroup'" -ForegroundColor Cyan
az webapp restart -g $SliResourceGroup -n $AppName -o none
Write-Host '    restart requested' -ForegroundColor Green
Write-Host '==> Watch the SLI :value series recover over the next few evaluation cycles.' -ForegroundColor Green
