<#
.SYNOPSIS
  Correlate the last deployment and guide a rollback of the backend App Service.

.DESCRIPTION
  When a regression correlates with a recent deploy, roll back rather than restart. The SLI demo uses
  zip deploy, so a true rollback means redeploying the previous artifact. This runbook lists the recent
  deployments (so the agent can cite the offending one) and prints the rollback command. It does NOT
  redeploy automatically, because the previous artifact must be supplied.

.EXAMPLE
  ./rollback-deploy.ps1
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

Write-Host "==> Recent deployments for '$AppName'" -ForegroundColor Cyan
$deployments = az webapp deployment list-publishing-profiles -g $SliResourceGroup -n $AppName -o none 2>$null
az webapp log deployment list -g $SliResourceGroup -n $AppName --query "[0:5].{id:id, status:status, author:author, message:message, time:end_time}" -o table 2>$null

Write-Host ''
Write-Host '==> Rollback options (choose the previous known-good build):' -ForegroundColor Cyan
Write-Host "    - Redeploy the previous artifact:  az webapp deploy -g $SliResourceGroup -n $AppName --src-path <previous.zip> --type zip"
Write-Host "    - Or swap slots if you use deployment slots:  az webapp deployment slot swap -g $SliResourceGroup -n $AppName --slot staging --target-slot production"
Write-Host '    Then confirm the SLI :value recovers before closing the incident.' -ForegroundColor Green
