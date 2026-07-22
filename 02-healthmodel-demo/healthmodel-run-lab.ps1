<#
.SYNOPSIS
  Interactive walkthrough of the Health Model Lab, Phase 1 through Phase 6.

.DESCRIPTION
  Runs the health model build end to end against a deployed SLI/SLO demo. It is the
  companion to ../01-sli-demo/sli-run-lab.ps1: where that lab authors the SLIs, this lab turns
  those SLIs into an Azure Monitor Health Model (preview). The health model is the NEXT
  PHASE after SLIs: it derives its health signals directly from the SLIs the Service Group
  already publishes (the ns::<servicegroup>/m::<sli>:value series in the Azure Monitor
  Workspace), so health and reliability agree on the exact same numbers.

  Phase 0 (infrastructure) is NOT part of this script. Deploy the SLI demo first with
  ../01-sli-demo/infra/infra-deploy.ps1 and author the SLIs with ../01-sli-demo/infra/sli/deploy-sli.ps1.

  Baseline traffic is a PREREQUISITE and is NOT started by this script. Run
  ../01-sli-demo/load/generate-traffic-all.ps1 in a separate terminal first so the SLI :value
  series carry recent data before this lab runs (otherwise signals read "Unknown").

  Mapping to the health model build:
    Phase 1  Environment setup and access checks          (auto + confirm)
    Phase 2  Create the health model                       (calls src/healthmodel-deploy.ps1)
    Phase 3  Discover the app as entities                  (auto verify)
    Phase 4  Map the SLIs to entities (from the sli label) (auto, writes CSV)
    Phase 5  Configure signals + alerts                    (calls src/configure-signals-alerts.ps1)
    Phase 6  Validate end-to-end                           (auto)

.EXAMPLE
  ./healthmodel-run-lab.ps1

.EXAMPLE
  ./healthmodel-run-lab.ps1 -SliResourceGroup rg-sli-demo -StartPhase 4 -EndPhase 6

.NOTES
  Requires PowerShell 7+ and Azure CLI (signed in). The health-models CLI extension installs
  automatically. Continuous traffic against the SLI app is a manual prerequisite so the SLI
  :value series (and therefore the health signals) carry recent data.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  # Azure context / naming. Anything left blank is auto-filled from the SLI main deployment
  # outputs when available, otherwise you are prompted.
  [string]$Subscription,

  # Where the SLI app, Application Insights, and Azure Monitor Workspace live.
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$MainDeploymentName = 'main',

  # Health model resource group + region + name (Microsoft.CloudHealth is region-limited).
  [string]$ResourceGroup = 'rg-healthmodel-demo',
  [string]$Location = 'centralus',
  [string]$HealthModelName = 'hm-checkout-demo',

  # Discovered from the SLI deployment when omitted.
  [string]$Amw,
  [string]$Ai,
  [string]$ServiceGroup,

  # SLI -> entity role: services listed here map to the frontend App Service (Login); every
  # other service/dependency (checkout, payment) maps to the backend App Service (Checkout).
  # Latency-of-Login is a frontend concern; availability of checkout and its payment dependency
  # are backend concerns. Adjust for your own app.
  [string[]]$FrontendServices = @('login'),

  # Entity name patterns for the app's App Service entities (used to resolve the mapping).
  [string]$FrontendLike = '*-fe-*',
  [string]$BackendLike = '*-be-*',

  # Optional action group to notify when an entity alert fires.
  [string]$ActionGroupId,

  # Phase gating.
  [ValidateRange(1, 6)][int]$StartPhase = 1,
  [ValidateRange(1, 6)][int]$EndPhase = 6,

  # Accept every default without prompting (best effort, uses judgement defaults).
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:NonInteractive = [bool]$NonInteractive
$script:Api = '2026-05-01-preview'
$script:SliApi = '2025-03-01-preview'
$script:Mgmt = 'https://management.azure.com'

# ---------------------------------------------------------------------------
# Presentation + input helpers (shared shape with ../01-sli-demo/sli-run-lab.ps1)
# ---------------------------------------------------------------------------
function Write-Phase([int]$Number, [string]$Title) {
  Write-Host ''
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
  Write-Host ("  PHASE {0}: {1}" -f $Number, $Title) -ForegroundColor Cyan
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Good([string]$Message) { Write-Host "    $Message" -ForegroundColor Green }

function Read-WithDefault([string]$Prompt, [string]$Default) {
  if ($script:NonInteractive) { return $Default }
  $suffix = if ($Default) { " [$Default]" } else { '' }
  $ans = Read-Host ("{0}{1}" -f $Prompt, $suffix)
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default } else { return $ans.Trim() }
}
function Confirm-Yes([string]$Message, [bool]$DefaultYes = $true) {
  if ($script:NonInteractive) { return $DefaultYes }
  $hint = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }
  $ans = Read-Host "$Message $hint"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
  return ($ans -match '^(y|yes)$')
}
function Pause-Phase([int]$Number) {
  if ($script:NonInteractive) { return }
  [void](Read-Host ("-- Phase {0} complete. Press Enter to continue" -f $Number))
}

# ---------------------------------------------------------------------------
# Prometheus query helpers (for confirming the SLI :value series carry data)
# ---------------------------------------------------------------------------
$script:Prom = $null
$script:PromToken = $null
$script:PromTokenExp = [datetime]::MinValue

function Get-PromToken {
  if ($script:PromToken -and (Get-Date) -lt $script:PromTokenExp.AddMinutes(-2)) { return $script:PromToken }
  $t = az account get-access-token --resource 'https://prometheus.monitor.azure.com' -o json | ConvertFrom-Json
  $script:PromToken = $t.accessToken
  $script:PromTokenExp = [datetime]$t.expiresOn
  return $script:PromToken
}

function Invoke-Prom([string]$Query) {
  if (-not $script:Prom) { throw 'Prometheus endpoint not resolved. Run Phase 1 first.' }
  $token = Get-PromToken
  $resp = Invoke-RestMethod -Method Post -Uri "$($script:Prom)/api/v1/query" `
    -Headers @{ Authorization = "Bearer $token" } -Body @{ query = $Query }
  return $resp.data.result
}

# Return the first scalar value of an instant query, or $null when empty/NaN.
function Get-PromScalar([string]$Query) {
  $r = Invoke-Prom $Query
  if (-not $r -or $r.Count -eq 0) { return $null }
  $v = $r[0].value[1]
  if ($v -eq 'NaN') { return $null }
  return [double]$v
}

# All published metric names in the AMW (used to locate the ns::<sg>/m::<sli>:value series).
function Get-PromMetricNames {
  $token = Get-PromToken
  return (Invoke-RestMethod -Uri "$($script:Prom)/api/v1/label/__name__/values" `
      -Headers @{ Authorization = "Bearer $token" }).data
}

# ---------------------------------------------------------------------------
# Resource discovery helpers
# ---------------------------------------------------------------------------
function Find-RgResource([string]$Rg, [string]$Type, [string]$Label) {
  $names = @(az resource list -g $Rg --resource-type $Type --query '[].name' -o tsv 2>$null | Where-Object { $_ })
  if (-not $names -or $names.Count -eq 0) { return $null }
  if ($names.Count -eq 1) { return $names[0] }
  Write-Info "Multiple ${Label}(s) found in ${Rg}:"
  for ($i = 0; $i -lt $names.Count; $i++) { Write-Info ("  [{0}] {1}" -f $i, $names[$i]) }
  if ($script:NonInteractive) { return $names[0] }
  $raw = Read-WithDefault "  Pick $Label index" '0'
  [int]$idx = 0
  if (-not [int]::TryParse($raw, [ref]$idx) -or $idx -lt 0 -or $idx -ge $names.Count) { $idx = 0 }
  return $names[$idx]
}

# Check whether a tenant-scoped Service Group already exists (preview API, via az rest).
function Test-ServiceGroupExists([string]$Name) {
  try {
    $url = "$($script:Mgmt)/providers/Microsoft.Management/serviceGroups/$Name`?api-version=2024-02-01-preview"
    $r = az rest --method get --url $url 2>$null
    return ($LASTEXITCODE -eq 0 -and $r)
  } catch { return $false }
}

# List the SLIs authored on the Service Group (control plane). This is the source of truth for
# which SLIs exist; the runner derives one health signal per SLI from this list.
function Get-ServiceGroupSlis([string]$Name) {
  $url = "$($script:Mgmt)/providers/Microsoft.Management/serviceGroups/$Name/providers/Microsoft.Monitor/slis?api-version=$($script:SliApi)"
  try {
    $resp = az rest --method get --url $url 2>$null | ConvertFrom-Json
    return @($resp.value)
  } catch { return @() }
}

# Derive the service/dependency label an SLI measures ("the sli label"). Prefer the authored SLI
# definition (its good/total PromQL carries service="..." or dependency="..."); fall back to the
# SLI name. This is what lets the health model attach each SLI to the right entity with no manual map.
function Get-SliServiceToken([string]$SgName, [string]$SliName) {
  $url = "$($script:Mgmt)/providers/Microsoft.Management/serviceGroups/$SgName/providers/Microsoft.Monitor/slis/$SliName`?api-version=$($script:SliApi)"
  $svc = $null
  $kind = 'service'
  try {
    $detail = az rest --method get --url $url 2>$null | ConvertFrom-Json
    if ($detail) {
      $json = $detail | ConvertTo-Json -Depth 40
      if ($json -match 'dependency\s*=\s*\\?"?([A-Za-z0-9_.\-]+)') { $svc = $Matches[1]; $kind = 'dependency' }
      elseif ($json -match 'service\s*=\s*\\?"?([A-Za-z0-9_.\-]+)') { $svc = $Matches[1]; $kind = 'service' }
    }
  } catch { $svc = $null }
  if (-not $svc) {
    # Fall back to parsing well-known tokens out of the SLI name.
    foreach ($tok in @('login', 'checkout', 'payment')) {
      if ($SliName -match $tok) { $svc = $tok; if ($tok -eq 'payment') { $kind = 'dependency' }; break }
    }
  }
  return [pscustomobject]@{ Service = $svc; Kind = $kind }
}

# ---------------------------------------------------------------------------
# Shared state carried across phases
# ---------------------------------------------------------------------------
$script:Ai = $Ai
$script:Amw = $Amw
$script:Sg = $ServiceGroup
$script:AmwId = $null
$script:AiId = $null
$script:HmId = $null
$script:PrincipalId = $null
$script:Suffix = $null
$script:Slis = @()          # control-plane SLI names on the Service Group
$script:Map = @()           # derived SLI -> entity mapping rows

# ===========================================================================
# PHASE 1: Environment setup and access checks
# ===========================================================================
function Invoke-Phase1 {
  Write-Phase 1 'Environment setup and access checks'

  Write-Step '1.1 - Select your subscription and confirm the SLI demo exists'
  if ($Subscription) {
    Write-Info "Selecting subscription $Subscription"
    az account set --subscription $Subscription | Out-Null
  }
  $acct = az account show -o json | ConvertFrom-Json
  Write-Info ("Subscription : {0}" -f $acct.id)
  $script:TenantId = $acct.tenantId

  $exists = (az group exists -n $SliResourceGroup) -eq 'true'
  if (-not $exists) { throw "SLI resource group '$SliResourceGroup' not found. Deploy ../01-sli-demo/infra/infra-deploy.ps1 first." }
  Write-Good "SLI resource group '$SliResourceGroup' found."

  Write-Step '1.2 - Discover the SLI resources the health model reads'
  $dAi = Find-RgResource $SliResourceGroup 'Microsoft.Insights/components' 'Application Insights component'
  $dAmw = Find-RgResource $SliResourceGroup 'Microsoft.Monitor/accounts' 'Azure Monitor Workspace'
  if (-not $script:Ai) { $script:Ai = $dAi }
  if (-not $script:Amw) { $script:Amw = $dAmw }
  if (-not $script:Amw) { throw "No Azure Monitor Workspace found in '$SliResourceGroup'. The health model taps its SLI :value series." }
  if ($script:Ai) { Write-Good "Application Insights : $($script:Ai)" } else { Write-Warn 'No Application Insights component found (topology discovery bonus only).' }
  Write-Good "Azure Monitor Workspace : $($script:Amw)"

  # Derive the naming suffix from the AMW name (slidemo-amw-<suffix>).
  if ($script:Amw -match '-amw-(.+)$') { $script:Suffix = $Matches[1] }

  Write-Step '1.3 - Resolve the Service Group that owns the SLIs'
  $out = $null
  try { $out = az deployment group show -g $SliResourceGroup -n $MainDeploymentName --query properties.outputs -o json 2>$null | ConvertFrom-Json } catch { $out = $null }
  if (-not $script:Sg) {
    $script:Sg = if ($out.suggestedServiceGroupName) { $out.suggestedServiceGroupName.value }
    elseif ($script:Suffix) { "CheckoutSG-$($script:Suffix)" } else { '' }
  }
  $script:Sg = Read-WithDefault 'Service Group name (tenant-scoped, owns the SLIs)' $script:Sg
  if (-not $script:Sg) { throw 'A Service Group name is required (it names the SLIs the health model consumes).' }
  if (Test-ServiceGroupExists $script:Sg) { Write-Good "Service Group '$($script:Sg)' exists." }
  else { Write-Warn "Service Group '$($script:Sg)' not found. Author the SLIs first (../01-sli-demo/sli-run-lab.ps1)." }

  Write-Step '1.4 - Resolve the Prometheus query endpoint'
  $script:AmwId = az resource show -g $SliResourceGroup -n $script:Amw --resource-type 'Microsoft.Monitor/accounts' --query id -o tsv 2>$null
  if (-not $script:AmwId) { throw "Azure Monitor Workspace '$($script:Amw)' not found in '$SliResourceGroup'." }
  $script:Prom = az resource show --ids $script:AmwId --query 'properties.metrics.prometheusQueryEndpoint' -o tsv
  Write-Info "Endpoint: $($script:Prom)"
  if ($script:Ai) { $script:AiId = az resource show -g $SliResourceGroup -n $script:Ai --resource-type 'Microsoft.Insights/components' --query id -o tsv 2>$null }

  Write-Step '1.5 - Confirm the SLI :value series carry recent data (traffic prerequisite)'
  $sgLower = $script:Sg.ToLower()
  $names = @()
  try { $names = @(Get-PromMetricNames) } catch { $names = @() }
  $valueSeries = @($names | Where-Object { $_ -like "ns::$sgLower/m::*:value" })
  if ($valueSeries.Count -eq 0) {
    Write-Warn 'No published SLI :value series found for this Service Group.'
    Write-Info 'The health signals read these series, so author the SLIs and keep traffic flowing:'
    Write-Info '  ../01-sli-demo/sli-run-lab.ps1   (authors the SLIs)'
    Write-Info ("  ../01-sli-demo/load/generate-traffic-all.ps1 -ResourceGroup {0} -Rps 25" -f $SliResourceGroup)
    if (-not (Confirm-Yes 'Continue anyway (signals will read Unknown until the series exist)?' $false)) {
      throw 'Aborted: no SLI :value series. Author the SLIs and start traffic, then re-run.'
    }
  }
  else {
    foreach ($s in $valueSeries) {
      $v = Get-PromScalar ('last_over_time({__name__="' + $s + '"}[1h])')
      $short = ($s -replace '^ns::[^/]+/m::', '') -replace ':value$', ''
      if ($null -ne $v) { Write-Good ("{0} = {1:n3}" -f $short, $v) } else { Write-Warn ("{0} = no recent sample" -f $short) }
    }
  }

  Write-Step '1.6 - Choose the health model to create or update'
  Write-Info 'Microsoft.CloudHealth is region-limited; keep a supported region such as centralus.'

  # Discover existing health models in the subscription once, so an existing one can be reused by
  # selection instead of retyping its name / resource group / region.
  $existingHm = @()
  try { $existingHm = @(az resource list --resource-type 'Microsoft.CloudHealth/healthmodels' --query "[].{name:name, rg:resourceGroup, loc:location}" -o json 2>$null | ConvertFrom-Json) } catch { $existingHm = @() }

  while ($true) {
    if (-not $script:NonInteractive) {
      $picked = $false
      if ($existingHm.Count -gt 0) {
        Write-Info 'Existing health models in this subscription (select one to reuse, or create new):'
        for ($i = 0; $i -lt $existingHm.Count; $i++) {
          Write-Info ("  [{0}] {1}  ({2} / {3})" -f $i, $existingHm[$i].name, $existingHm[$i].rg, $existingHm[$i].loc)
        }
        Write-Info '  [n] Create a new health model'
        $sel = Read-WithDefault 'Select a model number to reuse, or n to create new' 'n'
        [int]$idx = -1
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $existingHm.Count) {
          $script:HealthModelName = $existingHm[$idx].name
          $script:ResourceGroup = $existingHm[$idx].rg
          $script:Location = $existingHm[$idx].loc
          $picked = $true
        }
      }
      # Only prompt for the individual fields when creating a NEW model.
      if (-not $picked) {
        Write-Info 'New health model (press Enter to accept each default):'
        $script:HealthModelName = Read-WithDefault 'Health model name' $HealthModelName
        $script:ResourceGroup = Read-WithDefault 'Health model resource group' $ResourceGroup
        $script:Location = Read-WithDefault 'Health model region' $Location
      }
    }

    $hmState = if (az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json 2>$null) { 'exists (Phase 2 reconciles it)' } else { 'new (Phase 2 creates it)' }

    Write-Host ''
    Write-Host '  Confirmed configuration:' -ForegroundColor White
    [pscustomobject]@{
      Subscription      = $acct.id
      SliResourceGroup  = $SliResourceGroup
      AMW               = $script:Amw
      AppInsights       = $script:Ai
      ServiceGroup      = $script:Sg
      HealthModel       = $HealthModelName
      HealthModelRG     = $ResourceGroup
      HealthModelRegion = $Location
      HealthModelState  = $hmState
      SliValueSeries    = $valueSeries.Count
    } | Format-List | Out-Host

    if (Confirm-Yes 'Proceed with these values?' $true) { break }
    if ($script:NonInteractive) { break }
    if (-not (Confirm-Yes 'Choose again (select a different model or create new)?' $true)) {
      Write-Warn 'Aborted at the confirmation step. No changes were made.'
      exit 1
    }
  }

  Pause-Phase 1
}

# ===========================================================================
# PHASE 2: Create the health model
# ===========================================================================
function Invoke-Phase2 {
  Write-Phase 2 'Create the health model'
  Write-Info 'Creates the model + system-assigned identity, grants Monitoring Reader on the SLI'
  Write-Info 'resource group, binds the authentication setting, and creates the discovery rule.'

  $deploy = Join-Path $PSScriptRoot 'src/healthmodel-deploy.ps1'
  if (-not (Test-Path $deploy)) { throw "src/healthmodel-deploy.ps1 not found at $deploy." }

  $hm = az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json 2>$null | ConvertFrom-Json
  if ($hm) {
    Write-Good "Health model '$HealthModelName' already exists (src/healthmodel-deploy.ps1 is idempotent)."
    # Self-heal: discovery needs the identity to hold Monitoring Reader on the SLI resource group.
    $needsRole = $true
    $idPrincipal = $hm.identity.principalId
    if ($idPrincipal) {
      $sliScope = az group show -n $SliResourceGroup --query id -o tsv 2>$null
      if ($sliScope) {
        $ra = az role assignment list --assignee $idPrincipal --scope $sliScope --role 'Monitoring Reader' -o json 2>$null | ConvertFrom-Json
        if ($ra -and $ra.Count -gt 0) { $needsRole = $false }
      }
    }
    if ($needsRole) {
      Write-Warn "Identity is missing 'Monitoring Reader' on '$SliResourceGroup'; discovery cannot read the app. Re-running src/healthmodel-deploy.ps1 to reconcile."
      $run = $true
    }
    else {
      $run = Confirm-Yes 'Re-run src/healthmodel-deploy.ps1 to reconcile the model + discovery rule?' $false
    }
  }
  else {
    Write-Warn "Health model '$HealthModelName' does not exist yet."
    $run = Confirm-Yes 'Run src/healthmodel-deploy.ps1 now to create the model and discovery rule?' $true
  }

  if ($run) {
    Write-Step '2.1 - Invoking src/healthmodel-deploy.ps1'
    $splat = @{ ResourceGroup = $ResourceGroup; Location = $Location; HealthModelName = $HealthModelName; SliResourceGroup = $SliResourceGroup; NonInteractive = $true }
    if ($script:AiId) { $splat.AppInsightsResourceId = $script:AiId }
    & $deploy @splat
  }
  else { Write-Info 'Skipped src/healthmodel-deploy.ps1 (model left as-is).' }

  $hm = az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json 2>$null | ConvertFrom-Json
  if (-not $hm) { throw "Health model '$HealthModelName' still not present. Re-run Phase 2." }
  $script:HmId = $hm.id
  $script:PrincipalId = $hm.identity.principalId
  Write-Good "Health model id: $($script:HmId)"

  Pause-Phase 2
}

# ===========================================================================
# PHASE 3: Discover the app as entities
# ===========================================================================
function Invoke-Phase3 {
  Write-Phase 3 'Discover the app as entities'
  Write-Info 'Discovery runs on a fixed 5-minute cycle and imports the workload App Services as'
  Write-Info 'entities. This phase verifies the entities exist before signals are attached.'

  Write-Step '3.1 - Enumerate discovered entities'
  $entities = @()
  $attempt = 0
  do {
    $attempt++
    $entities = @(az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o json 2>$null | ConvertFrom-Json)
    $apps = @($entities | Where-Object { $_.properties.displayName -like $FrontendLike -or $_.properties.displayName -like $BackendLike })
    if ($apps.Count -ge 1) { break }
    if ($attempt -ge 3) { break }
    Write-Warn 'No app App Service entities yet. Discovery runs every 5 minutes.'
    if (-not (Confirm-Yes 'Wait 60s and re-check?' $true)) { break }
    Start-Sleep -Seconds 60
  } while ($true)

  if ($entities.Count -eq 0) {
    Write-Warn 'No entities discovered yet. Allow ~5 to 10 minutes after Phase 2, then re-run Phase 3.'
  }
  else {
    $entities | ForEach-Object {
      $role = if ($_.properties.displayName -like $FrontendLike -and $_.properties.displayName -notlike '*-plan') { 'frontend (Login)' }
      elseif ($_.properties.displayName -like $BackendLike -and $_.properties.displayName -notlike '*-plan') { 'backend (Checkout)' }
      else { 'supporting' }
      [pscustomobject]@{ DisplayName = $_.properties.displayName; Role = $role }
    } | Format-Table DisplayName, Role -AutoSize | Out-Host
    Write-Good ("{0} entit{1} discovered." -f $entities.Count, $(if ($entities.Count -eq 1) { 'y' } else { 'ies' }))
  }
  $script:Entities = $entities

  Pause-Phase 3
}

# ===========================================================================
# PHASE 4: Map the SLIs to entities (derive from the sli label)
# ===========================================================================
function Invoke-Phase4 {
  Write-Phase 4 'Map the SLIs to entities (derive from the sli label)'
  Write-Info 'The health model derives its health signals from the SLIs. For each SLI authored on'
  Write-Info 'the Service Group, read the service/dependency it measures (the "sli label"), confirm'
  Write-Info 'its ns::<sg>/m::<sli>:value series exists, and map it to the App Service entity that'
  Write-Info 'serves that part of the journey. No manual mapping table is kept.'

  Write-Step '4.1 - Enumerate the SLIs authored on the Service Group'
  $script:Slis = @(Get-ServiceGroupSlis $script:Sg)
  if ($script:Slis.Count -eq 0) {
    Write-Warn 'No SLIs found on the Service Group (control plane). Author them first with ../01-sli-demo/sli-run-lab.ps1.'
    Pause-Phase 4
    return
  }
  Write-Good ("Authored SLIs: {0}" -f (($script:Slis.name) -join ', '))

  Write-Step '4.2 - Derive the sli label and locate the published :value series'
  $sgLower = $script:Sg.ToLower()
  $names = @()
  try { $names = @(Get-PromMetricNames) } catch { $names = @() }

  # Resolve the discovered app entities from the LIVE list (discovery may have advanced since Phase 3,
  # so do not reuse a possibly-stale snapshot).
  $entities = @(az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o json 2>$null | ConvertFrom-Json)
  $script:Entities = $entities
  $feEntity = $entities | Where-Object { $_.properties.displayName -like $FrontendLike -and $_.properties.displayName -notlike '*-plan' } | Select-Object -First 1
  $beEntity = $entities | Where-Object { $_.properties.displayName -like $BackendLike -and $_.properties.displayName -notlike '*-plan' } | Select-Object -First 1

  $rows = @()
  foreach ($sli in $script:Slis) {
    $sliName = $sli.name
    $sliLower = $sliName.ToLower()
    $tok = Get-SliServiceToken $script:Sg $sliName
    $svc = $tok.Service
    $role = if ($svc -and ($svc -in $FrontendServices)) { 'frontend' } else { 'backend' }
    $entity = if ($role -eq 'frontend') { $feEntity } else { $beEntity }
    $series = @($names | Where-Object { $_ -eq "ns::$sgLower/m::${sliLower}:value" }) | Select-Object -First 1
    $present = [bool]$series
    $value = $null
    if ($present) { $value = Get-PromScalar ('last_over_time({__name__="' + $series + '"}[1h])') }
    $rows += [pscustomobject]@{
      Sli        = $sliName
      Label      = if ($svc) { "$($tok.Kind)=$svc" } else { '(unresolved)' }
      Role       = $role
      Entity     = if ($entity) { $entity.properties.displayName } else { '(not discovered)' }
      Value      = if ($null -ne $value) { [math]::Round($value, 3) } else { $null }
      SeriesFound = $present
    }
  }
  $script:Map = $rows
  $rows | Format-Table Sli, Label, Role, Entity, Value, SeriesFound -AutoSize | Out-Host

  $missing = @($rows | Where-Object { -not $_.SeriesFound })
  if ($missing.Count -gt 0) { Write-Warn ("{0} SLI(s) have no :value series yet (keep traffic running / re-author): {1}" -f $missing.Count, (($missing.Sli) -join ', ')) }
  $unmapped = @($rows | Where-Object { $_.Entity -eq '(not discovered)' })
  if ($unmapped.Count -gt 0) { Write-Warn ("{0} SLI(s) have no target entity yet (allow discovery to run): {1}" -f $unmapped.Count, (($unmapped.Sli) -join ', ')) }

  Write-Step '4.3 - Write the entity/SLI map'
  $csv = Join-Path $PSScriptRoot 'healthmodel-entity-map.csv'
  $rows | Export-Csv -NoTypeInformation $csv
  Write-Good "Entity/SLI map written to $csv."

  Pause-Phase 4
}

# ===========================================================================
# PHASE 5: Configure signals + alerts
# ===========================================================================
function Invoke-Phase5 {
  Write-Phase 5 'Configure signals + alerts'
  Write-Info 'Attaches one Azure Monitor workspace (PromQL) signal per SLI to its mapped entity so'
  Write-Info 'the entity health is driven by the stored SLI value, and enables Degraded/Unhealthy'
  Write-Info 'state alerts. src/configure-signals-alerts.ps1 applies the mapping surfaced in Phase 4.'

  $configure = Join-Path $PSScriptRoot 'src/configure-signals-alerts.ps1'
  if (-not (Test-Path $configure)) { throw "src/configure-signals-alerts.ps1 not found at $configure." }

  if (Confirm-Yes 'Run src/configure-signals-alerts.ps1 now?' $true) {
    Write-Step '5.1 - Invoking src/configure-signals-alerts.ps1'
    $splat = @{ ResourceGroup = $ResourceGroup; HealthModelName = $HealthModelName; SliResourceGroup = $SliResourceGroup; ServiceGroup = $script:Sg; FrontendLike = $FrontendLike; BackendLike = $BackendLike }
    if ($script:AmwId) { $splat.AmwResourceId = $script:AmwId }
    if ($ActionGroupId) { $splat.ActionGroupId = $ActionGroupId }
    & $configure @splat
  }
  else {
    Write-Info 'Skipped. Apply later with:'
    Write-Info ("  ./src/configure-signals-alerts.ps1 -ResourceGroup {0} -SliResourceGroup {1}" -f $ResourceGroup, $SliResourceGroup)
  }

  Pause-Phase 5
}

# ===========================================================================
# PHASE 6: Validate end-to-end
# ===========================================================================
function Invoke-Phase6 {
  Write-Phase 6 'Validate end-to-end'
  Write-Info 'Confirm each app entity carries its SLI signal(s), read the current health states, and'
  Write-Info 'confirm the model root rolls up the workload.'

  Write-Step '6.1 - Entity health states and attached SLI signals'
  if (-not $script:HmId) {
    $hm = az monitor health-models show -g $ResourceGroup -n $HealthModelName -o json 2>$null | ConvertFrom-Json
    if ($hm) { $script:HmId = $hm.id }
  }
  $entities = @(az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o json 2>$null | ConvertFrom-Json)
  if ($entities.Count -eq 0) { Write-Warn 'No entities found. Run Phases 2 to 5 first.'; Pause-Phase 6; return }

  $view = foreach ($e in $entities) {
    $amwSignals = @($e.properties.signalGroups.azureMonitorWorkspace.signals | ForEach-Object { $_.displayName })
    $state = if ($e.properties.healthState) { $e.properties.healthState } elseif ($e.properties.status) { $e.properties.status } else { 'Unknown' }
    [pscustomobject]@{
      Entity     = $e.properties.displayName
      Health     = $state
      SliSignals = if ($amwSignals.Count -gt 0) { $amwSignals -join ', ' } else { '-' }
    }
  }
  $view | Format-Table Entity, Health, SliSignals -AutoSize | Out-Host

  Write-Step '6.2 - Confirm the SLI signals reference the stored :value series'
  if ($script:Map -and $script:Map.Count -gt 0) {
    # Re-resolve entities from the live list: Phase 4 may have built the map before discovery finished,
    # so an entity recorded as '(not discovered)' can be resolved now by its role.
    $liveEnts = @(az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o json 2>$null | ConvertFrom-Json)
    $liveFe = ($liveEnts | Where-Object { $_.properties.displayName -like $FrontendLike -and $_.properties.displayName -notlike '*-plan' } | Select-Object -First 1).properties.displayName
    $liveBe = ($liveEnts | Where-Object { $_.properties.displayName -like $BackendLike -and $_.properties.displayName -notlike '*-plan' } | Select-Object -First 1).properties.displayName
    foreach ($m in ($script:Map | Where-Object { $_.SeriesFound })) {
      $ent = if ($m.Entity -and $m.Entity -ne '(not discovered)') { $m.Entity } elseif ($m.Role -eq 'frontend') { $liveFe } else { $liveBe }
      if (-not $ent) { $ent = '(not discovered)' }
      if ($null -ne $m.Value) { Write-Good ("{0} -> {1}: stored SLI value = {2}" -f $m.Sli, $ent, $m.Value) }
      else { Write-Warn ("{0} -> {1}: series present but no recent sample (start traffic)" -f $m.Sli, $ent) }
    }
  }
  else { Write-Info 'No in-memory map (run Phase 4 in the same session to cross-check values).' }

  Write-Step '6.3 - Confirm the model root rolls up the topology'
  $relResp = az rest --method get --url "$($script:Mgmt)$($script:HmId)/relationships?api-version=$($script:Api)" 2>$null | ConvertFrom-Json
  $rels = @($relResp.value)
  $rootLink = $rels | Where-Object { $_.properties.parentEntityName -eq $HealthModelName } | Select-Object -First 1
  if ($rootLink) { Write-Good ("Root '{0}' links to '{1}' (workload rolls up into the model root)." -f $HealthModelName, $rootLink.properties.childEntityName) }
  else { Write-Warn 'No root->topology relationship found. Re-run Phase 5 (src/configure-signals-alerts.ps1 creates it).' }

  $portalUrl = "https://portal.azure.com/#@$($script:TenantId)/resource$($script:HmId)/overview"
  Write-Info "Portal (Graph view): $portalUrl"

  Pause-Phase 6
}

# ===========================================================================
# Main
# ===========================================================================
if ($StartPhase -gt $EndPhase) { throw '-StartPhase must be <= -EndPhase.' }

Write-Host ''
Write-Host 'Health Model Lab - interactive runner' -ForegroundColor Cyan
Write-Host ("Phases {0} to {1}{2}" -f $StartPhase, $EndPhase, ($(if ($script:NonInteractive) { ' (non-interactive)' } else { '' }))) -ForegroundColor DarkCyan

# Phase 1 always runs first when in range, because later phases need its context.
if ($StartPhase -gt 1) {
  Write-Warn 'Phases 2+ need the Phase 1 context (endpoint, service group, resources). Running Phase 1 setup first.'
  Invoke-Phase1
}
elseif ($StartPhase -le 1 -and $EndPhase -ge 1) {
  Invoke-Phase1
}

if ($StartPhase -le 2 -and $EndPhase -ge 2) { Invoke-Phase2 }
if ($StartPhase -le 3 -and $EndPhase -ge 3) { Invoke-Phase3 }
if ($StartPhase -le 4 -and $EndPhase -ge 4) { Invoke-Phase4 }
if ($StartPhase -le 5 -and $EndPhase -ge 5) { Invoke-Phase5 }
if ($StartPhase -le 6 -and $EndPhase -ge 6) { Invoke-Phase6 }

# Phase 7: completion checklist.
Write-Phase 7 'Lab completion checklist'
Write-Info 'Phase 1: SLI resources resolved and the SLI :value series carry data.'
Write-Info 'Phase 2: health model + system identity created, discovery rule in place.'
Write-Info 'Phase 3: workload App Services discovered as entities.'
Write-Info 'Phase 4: each SLI mapped to an entity from its sli label (healthmodel-entity-map.csv).'
Write-Info 'Phase 5: one AMW PromQL signal per SLI attached, Degraded/Unhealthy alerts enabled.'
Write-Info 'Phase 6: entity health states read and the root rolls up the workload.'
if ($script:Map -and $script:Map.Count -gt 0) {
  Write-Good ("Mapped SLIs: {0}" -f (($script:Map.Sli) -join ', '))
}
Write-Info 'Operate and iterate: the health model is the state-based view over the SLIs; review alongside the SLO review.'

# Optional cleanup: delete the health model and its role assignment (teardown.ps1). The SLI demo is
# never touched.
$teardown = Join-Path $PSScriptRoot 'teardown.ps1'
if (Test-Path $teardown) {
  Write-Host ''
  Write-Step 'Cleanup (optional)'
  Write-Warn "This DELETES health model '$HealthModelName' and its Monitoring Reader role (the SLI demo is left intact)."
  # Teardown is destructive, so it never runs automatically. Under -NonInteractive we default to
  # keeping the model (safe) and print the manual command instead of blocking on a prompt.
  $ans = if ($script:NonInteractive) { 'n' } else { Read-Host ("Delete health model '{0}' now? (y/N)" -f $HealthModelName) }
  if ($ans -match '^(y|yes)$') {
    & $teardown -ResourceGroup $ResourceGroup -HealthModelName $HealthModelName -SliResourceGroup $SliResourceGroup
    Write-Good 'Teardown complete.'
  }
  else {
    Write-Info 'Left in place. Delete later with:'
    Write-Info ("  ./teardown.ps1 -ResourceGroup {0} -HealthModelName {1}" -f $ResourceGroup, $HealthModelName)
    Write-Info ("  ./teardown.ps1 -ResourceGroup {0} -HealthModelName {1} -DeleteResourceGroup   # also delete the resource group" -f $ResourceGroup, $HealthModelName)
  }
}

Write-Host ''
Write-Good 'Lab run complete.'
