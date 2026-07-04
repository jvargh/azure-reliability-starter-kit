# deploy.ps1
# One-stop, fully automated deploy of the Azure Monitor SLI/SLO demo (App Service only, no ACA).
#
# It provisions all infrastructure with Bicep (monitoring, identity + roles, the OpenTelemetry
# Collector container web app, the managed-identity remote-write proxy, and the frontend/backend
# apps), then pushes the Node app code. After it finishes, create the Service Group and author the
# SLIs in the portal (see ../sli/01-sli-authoring-runbook.md).
#
# Usage:
#   ./deploy.ps1 -ResourceGroup rg-sli-demo -Location eastus2
#   ./deploy.ps1 -ResourceGroup rg-sli-demo -Location eastus2 -PlanSku B1 -GenerateTraffic

[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$Location = 'eastus2',
  [string]$NamePrefix = 'slidemo',
  [ValidateSet('P1v3', 'B1')][string]$PlanSku = 'P1v3',
  [switch]$GenerateTraffic
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # sli-demo/
$infra = $PSScriptRoot                            # sli-demo/infra
$src = Join-Path $root 'src'

function Publish-App($appName, $srcDir, [string[]]$include) {
  Write-Host "==> Deploying code to $appName" -ForegroundColor Cyan
  $zip = Join-Path $srcDir '..\_deploy.zip'
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Push-Location $srcDir
  Compress-Archive -Path $include -DestinationPath $zip -Force
  Pop-Location
  az webapp deploy -g $ResourceGroup -n $appName --src-path $zip --type zip --async true -o none
  Remove-Item $zip -Force
}

Write-Host "==> Ensuring resource group $ResourceGroup ($Location)" -ForegroundColor Cyan
az group create -n $ResourceGroup -l $Location -o none

Write-Host "==> Registering required resource providers" -ForegroundColor Cyan
az provider register --namespace Microsoft.Monitor -o none
az provider register --namespace Microsoft.Web -o none

Write-Host "==> Deploying infrastructure (Bicep)" -ForegroundColor Cyan
az deployment group create `
  -g $ResourceGroup -n main `
  -f (Join-Path $infra 'main.bicep') `
  -p namePrefix=$NamePrefix planSku=$PlanSku `
  -o none

$out = az deployment group show -g $ResourceGroup -n main --query properties.outputs -o json | ConvertFrom-Json
$backend = $out.backendName.value
$frontend = $out.frontendName.value
$proxy = $out.proxyName.value
$sg = $out.suggestedServiceGroupName.value
$feUrl = $out.frontendUrl.value

Write-Host "==> Deploying app code (backend, frontend, proxy)" -ForegroundColor Cyan
Publish-App $backend (Join-Path $src 'backend')   @('package.json', 'server.js', 'telemetry.js')
Publish-App $frontend (Join-Path $src 'frontend') @('package.json', 'server.js', 'telemetry.js', 'public')
Publish-App $proxy (Join-Path $src 'promproxy')   @('package.json', 'server.js')

Write-Host ""
Write-Host "==> Done. Resources deployed and code pushed." -ForegroundColor Green
Write-Host "Frontend:           $feUrl"
Write-Host "Backend:            $($out.backendUrl.value)"
Write-Host "Collector:          $($out.collectorUrl.value)"
Write-Host "Proxy:              $($out.proxyUrl.value)"
Write-Host "Azure Monitor WS:   $($out.azureMonitorWorkspaceName.value)"
Write-Host "Managed identity:   $($out.sliManagedIdentityClientId.value)"
Write-Host "Service Group name: $sg  (create it in the portal, add $ResourceGroup as a member)"
Write-Host ""
Write-Host "Next: create the Service Group, enable monitoring (default MI + AMW), and author SLIs."
Write-Host "See ../sli/01-sli-authoring-runbook.md"

if ($GenerateTraffic) {
  Write-Host "==> Starting traffic generator against $feUrl (Ctrl+C to stop)" -ForegroundColor Cyan
  $env:TARGET = $feUrl
  node (Join-Path $root 'load\generate-traffic.js') --rps 15 --duration 1800
}
