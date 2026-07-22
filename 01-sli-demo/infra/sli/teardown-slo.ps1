<#
.SYNOPSIS
  Tears down the SLI/SLO demo Service Group: deletes the SLIs, the monitoring
  settings, the resource-group membership relationship, and finally the Service
  Group itself. Reverse of deploy-sli.ps1. Recording rules and the AMW are left
  intact (they belong to the main deployment).

.EXAMPLE
  ./teardown-slo.ps1
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$MainDeploymentName = 'main',
  [string]$ServiceGroupName
)

$ErrorActionPreference = 'Stop'
$apiSli      = '2025-03-01-preview'
$apiSg       = '2024-02-01-preview'
$apiMember   = '2023-09-01-preview'
$apiSettings = '2025-06-03-preview'
$mgmt        = 'https://management.azure.com'

function Invoke-ArmDelete {
  param([Parameter(Mandatory)][string]$Url, [string]$Label)
  $raw = az rest --method delete --url $Url 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    if ($raw -match 'NotFound|ResourceNotFound|could not be found|404') {
      Write-Host "    $Label already gone" -ForegroundColor DarkGray
      return
    }
    throw $raw.Trim()
  }
  Write-Host "    $Label deleted" -ForegroundColor Green
}

$ctx      = az account show -o json | ConvertFrom-Json
$subId    = $ctx.id
$tenantId = $ctx.tenantId

if (-not $ServiceGroupName) {
  $out = (az deployment group show -g $ResourceGroup -n $MainDeploymentName --query properties.outputs -o json | ConvertFrom-Json)
  $ServiceGroupName = $out.suggestedServiceGroupName.value
}

Write-Host "==> Tearing down Service Group: $ServiceGroupName" -ForegroundColor Cyan

# 1. SLIs
Write-Host '==> Deleting SLIs' -ForegroundColor Cyan
foreach ($name in @('CheckoutAvailabilitySLI', 'LoginLatencySLI', 'PaymentDependencySLI')) {
  Invoke-ArmDelete -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/slis/$name`?api-version=$apiSli" -Label $name
}

# 2. Monitoring settings (default)
Write-Host '==> Deleting monitoring settings' -ForegroundColor Cyan
Invoke-ArmDelete -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName/providers/Microsoft.Monitor/settings/default`?api-version=$apiSettings" -Label 'settings/default'

# 3. Membership relationship
Write-Host '==> Deleting membership relationship' -ForegroundColor Cyan
$memberUri = "subscriptions/$subId/resourceGroups/$ResourceGroup"
Invoke-ArmDelete -Url "$mgmt/$memberUri/providers/Microsoft.Relationships/serviceGroupMember/$ServiceGroupName`?api-version=$apiMember" -Label 'serviceGroupMember'

# 4. Service Group
Write-Host '==> Deleting Service Group' -ForegroundColor Cyan
Invoke-ArmDelete -Url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName`?api-version=$apiSg" -Label $ServiceGroupName

# 5. Confirm
Write-Host '==> Confirming deletion' -ForegroundColor Cyan
$gone = $false
for ($i = 0; $i -lt 20; $i++) {
  $raw = az rest --method get --url "$mgmt/providers/Microsoft.Management/serviceGroups/$ServiceGroupName`?api-version=$apiSg" 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -and $raw -match 'NotFound|could not be found|404') { $gone = $true; break }
  Start-Sleep -Seconds 6
}
Write-Host ('    Service Group removed: {0}' -f $gone)
Write-Host ''
Write-Host 'Teardown complete. Recreate with: pwsh -File deploy-sli.ps1 -SkipRecordingRules' -ForegroundColor Green

# The confirmation loop's last `az rest` returns 404 (non-zero) once the SG is gone; reset the
# exit code so callers (sli-run-lab.ps1) do not see a false failure.
$global:LASTEXITCODE = 0
exit 0
