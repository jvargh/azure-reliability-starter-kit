<#
.SYNOPSIS
  Interactive walkthrough of SLI-Lab-UserGuide.md, Phase 1 through Phase 8.

.DESCRIPTION
  Runs the lab end to end against a deployed SLI/SLO demo (or your own app),
  stopping to collect input at each phase and taking user decisions where the
  lab calls for judgement (critical-journey scoring, SLI category, targets).

  Phase 0 (infrastructure) is NOT part of this script. Deploy the infra first
  with infra/infra-deploy.ps1, then run this. See SLI-Lab-UserGuide.md.

  Baseline traffic is also a PREREQUISITE and is NOT started by this script. Run
  load/generate-traffic-all.ps1 in a separate terminal first so the rolling-window
  SLI signals exist before the lab runs. See SLI-Lab-UserGuide.md.

  Mapping to the lab:
    Phase 1  Environment setup and access checks          (auto + confirm)
    Phase 2  Enumerate ALL user journeys                  (auto from telemetry)
    Phase 3  Extract the CRITICAL journeys                (prompts for scores)
    Phase 4  Data collection (per critical journey)       (auto + prompts)
    Phase 5  Consolidate into the design checklist        (auto, writes CSV)
    Phase 6  Author the SLIs in the portal                (optional deploy-sli.ps1)
    Phase 7  Validate end-to-end                          (auto)
    Phase 8  Lab completion checklist                     (summary)

.EXAMPLE
  ./sli-run-lab.ps1 -ResourceGroup rg-sli-demo

.EXAMPLE
  ./sli-run-lab.ps1 -ResourceGroup rg-sli-demo -StartPhase 4 -EndPhase 7

.NOTES
  Requires PowerShell 7+ and Azure CLI (signed in). Continuous traffic against the
  app is a manual prerequisite (start load/generate-traffic-all.ps1 in a separate
  terminal BEFORE running this script) so the rolling-window signals exist.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  # Azure context / naming. Anything left blank is auto-filled from the main
  # deployment outputs when available, otherwise you are prompted.
  [string]$Subscription,
  [string]$ResourceGroup = 'rg-sli-demo',
  [string]$NamePrefix    = 'slidemo',
  [string]$Suffix,
  [string]$Amw,
  [string]$Ai,
  [string]$ServiceGroup,
  [string]$MainDeploymentName = 'main',

  # Rolling lookback (days) used for the measured-performance queries in Phase 4.
  [int]$LookbackDays = 7,

  # Journeys where slowness (not failure) is the pain -> assigned the Latency SLI category in 3.3.
  # Latency cannot be inferred from telemetry; it is a judgement, so list those journeys here.
  [string[]]$LatencyJourneys = @('login'),

  # Phase gating.
  [ValidateRange(1, 8)][int]$StartPhase = 1,
  [ValidateRange(1, 8)][int]$EndPhase = 8,

  # Accept every default without prompting (best effort, uses judgement defaults).
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:NonInteractive = [bool]$NonInteractive

# ---------------------------------------------------------------------------
# Presentation + input helpers
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
function Read-IntInRange([string]$Prompt, [int]$Default, [int]$Min, [int]$Max) {
  while ($true) {
    $raw = Read-WithDefault $Prompt "$Default"
    [int]$val = 0
    if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min -and $val -le $Max) { return $val }
    Write-Warn "Enter a whole number between $Min and $Max."
  }
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
# Query helpers (Phase 1.3 / 1.4 in the lab)
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

# Build a PromQL string by replacing %TOKENS% (avoids brace/-f collisions).
function Expand-Query([string]$Template, [hashtable]$Vars) {
  foreach ($k in $Vars.Keys) { $Template = $Template.Replace("%$k%", [string]$Vars[$k]) }
  return $Template
}

function Invoke-AI([string]$Kql, [string]$Offset = '7d') {
  $resp = az monitor app-insights query --app $script:Ai -g $ResourceGroup --offset $Offset `
    --analytics-query $Kql -o json 2>$null | ConvertFrom-Json
  if (-not $resp) { return @() }
  $t = $resp.tables[0]
  $cols = @($t.columns.name)
  $out = @()
  foreach ($row in $t.rows) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
    $out += [pscustomobject]$o
  }
  return $out
}

function ConvertTo-Title([string]$Text) {
  if (-not $Text) { return $Text }
  return $Text.Substring(0, 1).ToUpper() + $Text.Substring(1)
}

# Discover a single resource name of a given type inside a resource group. Returns
# $null when none exist; when several exist, lets the user pick one.
function Find-RgResource([string]$Rg, [string]$Type, [string]$Label) {
  $names = @(az resource list -g $Rg --resource-type $Type --query '[].name' -o tsv 2>$null | Where-Object { $_ })
  if (-not $names -or $names.Count -eq 0) { return $null }
  if ($names.Count -eq 1) { return $names[0] }
  Write-Info "Multiple ${Label}(s) found in ${Rg}:"
  for ($i = 0; $i -lt $names.Count; $i++) { Write-Info ("  [{0}] {1}" -f $i, $names[$i]) }
  if ($script:NonInteractive) { return $names[0] }
  $idx = Read-IntInRange "  Pick $Label index" 0 0 ($names.Count - 1)
  return $names[$idx]
}

# Check whether a tenant-scoped Service Group already exists (preview API, via az rest).
# Returns $true when present, $false on 404/any error.
function Test-ServiceGroupExists([string]$Name) {
  try {
    $url = "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$Name`?api-version=2024-02-01-preview"
    $r = az rest --method get --url $url 2>$null
    return ($LASTEXITCODE -eq 0 -and $r)
  } catch { return $false }
}

# Sum the per-service request rates from a smoke-test result (0 when empty/all-zero).
function Get-RequestRateSum($Result) {
  if (-not $Result -or $Result.Count -eq 0) { return 0 }
  return ($Result | ForEach-Object { [double]$_.value[1] } | Measure-Object -Sum).Sum
}

# ---------------------------------------------------------------------------
# Shared state carried across phases
# ---------------------------------------------------------------------------
$script:Ai = $Ai
$script:Sg = $ServiceGroup
$script:Identity = $null
$script:SgExists = $false
$script:Inventory = @()
$script:Deps = @()
$script:Scored = @()
$script:Designs = @()

# ===========================================================================
# PHASE 1: Environment setup and access checks
# ===========================================================================
function Invoke-Phase1 {
  Write-Phase 1 'Environment setup and access checks'

  # 1.1 Select your subscription and set your variables
  Write-Step '1.1 - Select your subscription and set your variables'
  if ($Subscription) {
    Write-Info "Selecting subscription $Subscription"
    az account set --subscription $Subscription | Out-Null
  }
  $acct = az account show -o json | ConvertFrom-Json
  # Print only the subscription ID. The friendly name can embed a user alias, so it is not shown.
  Write-Info ("Subscription : {0}" -f $acct.id)

  # Discover the infra-deploy.ps1 resource group, then read its resources.
  Write-Info "infra-deploy.ps1 defaults its -ResourceGroup to 'rg-sli-demo'."
  $exists = $false
  do {
    $ResourceGroup = Read-WithDefault 'Resource group deployed by infra-deploy.ps1' $ResourceGroup
    $exists = (az group exists -n $ResourceGroup) -eq 'true'
    if (-not $exists) { Write-Warn "Resource group '$ResourceGroup' not found (or no access) in the current subscription." }
  } until ($exists -or $script:NonInteractive)
  if (-not $exists) { throw "Resource group '$ResourceGroup' not found in the current subscription." }

  Write-Info "Discovering resources in '$ResourceGroup'..."
  $dAmw = Find-RgResource $ResourceGroup 'Microsoft.Monitor/accounts' 'Azure Monitor Workspace'
  $dAi = Find-RgResource $ResourceGroup 'Microsoft.Insights/components' 'Application Insights component'
  $dId = Find-RgResource $ResourceGroup 'Microsoft.ManagedIdentity/userAssignedIdentities' 'user-assigned managed identity'
  $dLaw = Find-RgResource $ResourceGroup 'Microsoft.OperationalInsights/workspaces' 'Log Analytics workspace'

  if ($dAmw) { Write-Good "Azure Monitor Workspace : $dAmw" } else { Write-Warn 'No Azure Monitor Workspace found in the RG (SLI source/destination missing).' }
  if ($dAi) { Write-Good "Application Insights     : $dAi" } else { Write-Warn 'No Application Insights component found in the RG (bonus signal only).' }
  if ($dId) { Write-Good "Managed identity         : $dId" }
  if ($dLaw) { Write-Good "Log Analytics workspace  : $dLaw" }

  # Derive <prefix> and <suffix> from a discovered name (<prefix>-amw-<suffix>, etc.).
  $dPrefix = $NamePrefix; $dSuffix = $Suffix
  foreach ($pair in @(@($dAmw, 'amw'), @($dId, 'id'), @($dAi, 'ai'), @($dLaw, 'law'))) {
    $name = $pair[0]; $tag = $pair[1]
    if ($name -and $name -match "^(.*)-$tag-(.*)$") { $dPrefix = $Matches[1]; $dSuffix = $Matches[2]; break }
  }

  # Bonus: read the main deployment outputs when the deployment is still present.
  $out = $null
  try { $out = az deployment group show -g $ResourceGroup -n $MainDeploymentName --query properties.outputs -o json 2>$null | ConvertFrom-Json } catch { $out = $null }
  if (-not $dSuffix -and $out.namingSuffix) { $dSuffix = $out.namingSuffix.value }

  # Apply discovered values (explicit -params still win).
  if (-not $Amw) { $Amw = $dAmw }
  if (-not $script:Ai) { $script:Ai = $dAi }
  if (-not $Suffix) { $Suffix = $dSuffix }
  if (-not $PSBoundParameters.ContainsKey('NamePrefix') -and $dPrefix) { $NamePrefix = $dPrefix }
  $script:Identity = $dId

  # Inputs NOT discoverable from the RG (Service Group is tenant-scoped): require input.
  Write-Info 'Service Group is tenant-scoped (not in the RG); confirm it below.'
  Write-Info 'This is a free-text label you choose; it is NOT the infra naming suffix shown below'
  Write-Info ("(the deployed resources use suffix '{0}', e.g. {1}-amw-{0})." -f $Suffix, $NamePrefix)
  if (-not $script:Sg) {
    $script:Sg = if ($out.suggestedServiceGroupName) { $out.suggestedServiceGroupName.value }
    elseif ($dSuffix) { "CheckoutSG-$dSuffix" } else { '' }
  }
  $script:Sg = Read-WithDefault 'Service Group name (free-text label, tenant-scoped)' $script:Sg
  if (-not $script:Sg) { throw 'A Service Group name is required (it cannot be discovered from the resource group).' }

  Write-Info 'Checking whether the Service Group already exists...'
  $script:SgExists = Test-ServiceGroupExists $script:Sg
  if ($script:SgExists) {
    Write-Good "Service Group '$($script:Sg)' exists."
  } else {
    Write-Warn "Service Group '$($script:Sg)' does not exist yet; Phase 6 will create it (deploy-sli.ps1)."
  }

  # Let the user adjust the discovered values before locking them in.
  # Suffix, the Azure Monitor Workspace, and Application Insights are all derived from the resource
  # group's resource names, so only ask when discovery could not find them. Otherwise they are shown
  # in the confirmation summary below (answer No there to abort and re-run with explicit -Suffix/-Amw).
  if (-not $Suffix) { $Suffix = Read-WithDefault 'Naming suffix (not discovered)' $Suffix }
  if (-not $Amw) { $Amw = Read-WithDefault 'Azure Monitor Workspace name (not discovered)' $Amw }
  if (-not $script:Ai) { $script:Ai = Read-WithDefault 'Application Insights name (not discovered)' $script:Ai }
  if (-not $Amw) { throw 'An Azure Monitor Workspace name is required.' }

  # Persist to script scope so later phases use the confirmed values.
  $script:ResourceGroup = $ResourceGroup
  $script:NamePrefix = $NamePrefix
  $script:Suffix = $Suffix
  $script:Amw = $Amw

  # Resolve the frontend URL (shown to the user so they can point the manual traffic generator at it).
  $feUrl = if ($out.frontendUrl) { $out.frontendUrl.value }
  else { "https://$NamePrefix-fe-$Suffix.azurewebsites.net" }

  # 1.3 Confirm the full configuration before doing anything.
  Write-Host ''
  Write-Host '  Discovered / confirmed configuration:' -ForegroundColor White
  [pscustomobject]@{
    Subscription           = $acct.id
    ResourceGroup          = $ResourceGroup
    NamePrefix             = $NamePrefix
    'Suffix (infra names)' = $Suffix
    AMW                    = $Amw
    AppInsights            = $script:Ai
    ManagedIdentity        = $script:Identity
    'ServiceGroup (label)' = $script:Sg
    ServiceGroupExists     = $script:SgExists
  } | Format-List | Out-Host

  if (-not (Confirm-Yes 'Proceed with these values?' $true)) {
    throw 'Aborted by user at the discovery confirmation step. Re-run and adjust the inputs.'
  }

  # 1.2 Resolve the Prometheus query endpoint of the Azure Monitor Workspace
  Write-Step '1.2 - Resolve the Prometheus query endpoint of the Azure Monitor Workspace'
  $amwId = az resource show -g $ResourceGroup -n $Amw --resource-type 'Microsoft.Monitor/accounts' --query id -o tsv 2>$null
  if (-not $amwId) { throw "Azure Monitor Workspace '$Amw' not found in RG '$ResourceGroup'." }
  $script:AmwId = $amwId
  $script:Prom = az resource show --ids $amwId --query 'properties.metrics.prometheusQueryEndpoint' -o tsv
  Write-Info "Endpoint: $($script:Prom)"

  # 1.3 A reusable PromQL helper
  Write-Step '1.3 - A reusable PromQL helper'
  Write-Info 'Smoke test: services emitting request metrics (last 5m).'
  $svc = Invoke-Prom 'sum by (service) (rate(http_server_requests_total[5m]))'
  $haveMetrics = (Get-RequestRateSum $svc) -gt 0
  if ($haveMetrics) {
    $svc | ForEach-Object { Write-Good ("{0} = {1} req/s" -f $_.metric.service, [math]::Round([double]$_.value[1], 3)) }
  }

  # Baseline traffic is a PREREQUISITE, not part of this script. Every SLI signal is a rate over a
  # rolling 5m window, so the app must already be receiving continuous traffic before you run the
  # lab. Start load/generate-traffic-all.ps1 in a separate terminal first (see SLI-Lab-UserGuide.md).
  if (-not $haveMetrics) {
    Write-Warn 'No request metrics found. SLI signals are rolling-window rates, so the app must be'
    Write-Warn 'receiving continuous traffic BEFORE this lab runs (traffic is a manual prerequisite).'
    Write-Info 'Start the generator in a separate terminal, then re-run this script:'
    Write-Info ("  pwsh -File load/generate-traffic-all.ps1 -ResourceGroup {0} -Rps 25" -f $ResourceGroup)
    if (-not (Confirm-Yes 'Continue anyway (metrics-dependent phases may be empty)?' $false)) {
      throw 'Aborted: no live metrics. Start load/generate-traffic-all.ps1 first, then re-run.'
    }
  }

  # 1.4 Confirm Application Insights query access (for journey discovery)
  Write-Step '1.4 - Confirm Application Insights query access (for journey discovery)'
  Write-Info 'Bonus, not required; the PromQL path is sufficient.'
  $ok = az monitor app-insights query --app $script:Ai -g $ResourceGroup --analytics-query 'print ok=1' --query 'tables[0].rows[0][0]' -o tsv 2>$null
  if ($ok -eq '1') { Write-Good 'Application Insights query path works.' }
  else { Write-Warn 'Application Insights not reachable; continuing on the PromQL path.' }

  Pause-Phase 1
}

# ===========================================================================
# PHASE 2: Enumerate ALL user journeys
# ===========================================================================
function Invoke-Phase2 {
  Write-Phase 2 'Enumerate ALL user journeys'

  Write-Step '2.1 - Build the journey inventory from telemetry'
  Write-Info "Querying workspace metrics (last ${LookbackDays}d)..."
  $q = Expand-Query 'sum by (service, route) (increase(http_server_requests_total[%D%d]))' @{ D = $LookbackDays }
  $routes = Invoke-Prom $q | ForEach-Object {
    [pscustomobject]@{ Service = $_.metric.service; Route = $_.metric.route; Requests = [long][double]$_.value[1] }
  }
  if (-not $routes -or $routes.Count -eq 0) { throw 'No request metrics found. Ensure traffic is flowing and retry Phase 2.' }

  $total = ($routes | Measure-Object Requests -Sum).Sum
  $script:Deps = @(Invoke-Prom 'count by (dependency) (dependency_calls_total)' | ForEach-Object { $_.metric.dependency })

  $script:Inventory = $routes | Group-Object Service | ForEach-Object {
    $reqs = ($_.Group | Measure-Object Requests -Sum).Sum
    [pscustomobject]@{
      Journey    = $_.Name
      Routes     = ($_.Group.Route | Sort-Object -Unique) -join ', '
      Requests   = $reqs
      PctTraffic = [math]::Round(($reqs / $total) * 100, 1)
    }
  } | Sort-Object Requests -Descending

  $script:Inventory | Format-Table Journey, Routes, Requests, @{ n = 'Pct%'; e = { $_.PctTraffic } } -AutoSize | Out-Host
  Write-Info ("Dependencies observed: {0}" -f (($script:Deps -join ', ')))

  $csv = Join-Path $PSScriptRoot 'journey-inventory.csv'
  $script:Inventory | Export-Csv -NoTypeInformation $csv
  Write-Good "Inventory written to $csv."

  Write-Step '2.2 - Enrich and cross-check (what telemetry cannot infer)'
  Write-Info 'Annotate user goals and any uninstrumented journeys by hand in the CSV.'

  Pause-Phase 2
}

# ===========================================================================
# PHASE 3: Extract the CRITICAL journeys
# ===========================================================================

# Default an SLI category from a scored candidate: dependency rows become Dependency, journeys
# where slowness (not failure) is the pain (see -LatencyJourneys) become Latency, the rest default
# to Availability. Latency cannot be inferred from telemetry; it is a judgement listed by the user.
function Get-AutoCategory($cand, [string[]]$latency) {
  if ($cand.IsDependency) { return 'Dependency' }
  $base = ($cand.Journey -replace '\s*\(dep\)\s*$', '')
  if ($latency -contains $base) { return 'Latency' }
  return 'Availability'
}

function Show-CategoryTable($cands) {
  $cands | ForEach-Object {
    [pscustomobject]@{ Journey = $_.Journey; Category = $_.Category; Shape = 'Request-based' }
  } | Format-Table Journey, Category, Shape -AutoSize | Out-Host
}

function Invoke-Phase3 {
  Write-Phase 3 'Extract the CRITICAL journeys'
  if (-not $script:Inventory -or $script:Inventory.Count -eq 0) { throw 'Run Phase 2 first (no inventory in memory).' }

  function Get-FreqScore([double]$Pct) { if ($Pct -ge 30) { 3 } elseif ($Pct -ge 5) { 2 } else { 1 } }

  Write-Step '3.1 - Score each journey'
  Write-Info 'Rate each item 1 (low) to 3 (high). Frequency is derived from traffic share.'
  Write-Info 'Candidate threshold: total >= 9 of 12.'
  $rows = @()

  foreach ($j in $script:Inventory) {
    Write-Host ''
    Write-Host ("Journey: {0}  ({1}% of traffic, {2} requests)" -f $j.Journey, $j.PctTraffic, $j.Requests) -ForegroundColor White
    $isCheckout = ($j.Journey -eq 'checkout')
    $isLatencyJourney = ($LatencyJourneys -contains $j.Journey)
    $businessDefault = if ($isCheckout) { 3 } else { 2 }
    $visibilityDefault = if ($isCheckout -or $isLatencyJourney) { 3 } else { 2 }
    $blastDefault = if ($isCheckout -or $isLatencyJourney) { 3 } else { 2 }
    $business = Read-IntInRange '  Business impact (1-3)' $businessDefault 1 3
    $vis = Read-IntInRange '  User visibility (1-3)' $visibilityDefault 1 3
    $blast = Read-IntInRange '  Blast radius   (1-3)' $blastDefault 1 3
    $freq = Get-FreqScore $j.PctTraffic
    $rows += [pscustomobject]@{ Journey = $j.Journey; IsDependency = $false; Business = $business; Frequency = $freq; Visibility = $vis; BlastRadius = $blast }
  }

  foreach ($d in $script:Deps) {
    Write-Host ''
    Write-Host ("Dependency: {0}" -f $d) -ForegroundColor White
    $business = Read-IntInRange '  Business impact (1-3)' 3 1 3
    $vis = Read-IntInRange '  User visibility (1-3)' 2 1 3
    $blast = Read-IntInRange '  Blast radius   (1-3)' 3 1 3
    $rows += [pscustomobject]@{ Journey = "$d (dep)"; IsDependency = $true; Business = $business; Frequency = 3; Visibility = $vis; BlastRadius = $blast }
  }

  $script:Scored = $rows | Select-Object *,
  @{ n = 'Total'; e = { $_.Business + $_.Frequency + $_.Visibility + $_.BlastRadius } } |
  Select-Object *, @{ n = 'Candidate'; e = { if ($_.Total -ge 9) { 'Y' } else { 'N' } } } |
  Sort-Object Total -Descending

  Write-Step '3.2 - Criticality worksheet'
  Write-Host ''
  $script:Scored | Format-Table Journey, Business, Frequency, Visibility, BlastRadius, Total, Candidate -AutoSize | Out-Host
  $cands = @($script:Scored | Where-Object Candidate -eq 'Y')
  Write-Good ("{0} SLO candidate(s): {1}" -f $cands.Count, (($cands.Journey) -join ', '))

  # 3.3 Assign an SLI category per critical journey (auto-defaulted from the scored candidates).
  Write-Step '3.3 - Assign an SLI category per critical journey'
  Write-Info 'Auto-assigned: dependency rows become Dependency; journeys where slowness (not failure)'
  Write-Info 'is the pain are Latency (see -LatencyJourneys); everything else defaults to Availability.'
  foreach ($c in $cands) {
    $c | Add-Member -NotePropertyName Category -NotePropertyValue (Get-AutoCategory $c $LatencyJourneys) -Force
  }
  Write-Host ''
  Show-CategoryTable $cands

  # Present the results and let the user accept them or adjust before Phase 4 uses them.
  if (-not (Confirm-Yes 'Proceed with these SLI categories?' $true)) {
    foreach ($c in $cands) {
      $cat = Read-WithDefault ("  Category for {0} (Availability/Latency/Dependency)" -f $c.Journey) $c.Category
      $c.Category = (ConvertTo-Title $cat.ToLower())
    }
    Write-Host ''
    Show-CategoryTable $cands
  }

  Pause-Phase 3
}

# ===========================================================================
# PHASE 4: Data collection (per critical journey)
# ===========================================================================
function Invoke-Phase4 {
  Write-Phase 4 'Data collection (per critical journey)'
  $cands = @($script:Scored | Where-Object Candidate -eq 'Y')
  if ($cands.Count -eq 0) { throw 'No SLO candidates from Phase 3.' }

  $script:Designs = @()
  foreach ($c in $cands) {
    Write-Host ''
    Write-Host ("---- {0} ----" -f $c.Journey) -ForegroundColor White

    # SLI category was assigned in Phase 3 (3.3). Fall back to the auto-default when Phase 4 runs
    # standalone (e.g. -StartPhase 4) so a category is always present.
    $cat = if ($c.Category) { $c.Category } else { Get-AutoCategory $c $LatencyJourneys }

    # Resolve the metric label the SLI filters on.
    if ($cat -eq 'Dependency') {
      $label = Read-WithDefault '  Dependency label' (($c.Journey -replace '\s*\(dep\)\s*$', ''))
    } else {
      $label = Read-WithDefault '  Service label' $c.Journey
    }

    # 4.1 Confirm the source metric and required dimensions exist.
    Write-Step '4.1 - Confirm the source metric and required dimensions exist'
    switch ($cat) {
      'Availability' { $dimQ = Expand-Query 'count by (service, status_class) (http_server_requests_total{service="%L%"})' @{ L = $label } }
      'Latency' { $dimQ = Expand-Query 'count by (service) (sli:http_request_latency_total:rate5m{service="%L%"})' @{ L = $label } }
      'Dependency' { $dimQ = Expand-Query 'count by (dependency, status) (dependency_calls_total{dependency="%L%"})' @{ L = $label } }
    }
    $dims = Invoke-Prom $dimQ
    if (-not $dims -or $dims.Count -eq 0) { Write-Warn "No series for '$label'. Check the label and that traffic is flowing." }
    else { $dims | ForEach-Object { Write-Good (($_.metric.PSObject.Properties.Value) -join ' / ') } }

    # 4.2 Measure CURRENT performance (evidence for the target).
    Write-Step '4.2 - Measure CURRENT performance (evidence for the target)'
    Write-Info "Measuring over the last ${LookbackDays}d..."
    switch ($cat) {
      'Availability' {
        $mq = Expand-Query 'sum(increase(http_server_requests_total{service="%L%",status_class="2xx"}[%D%d])) / sum(increase(http_server_requests_total{service="%L%"}[%D%d]))' @{ L = $label; D = $LookbackDays }
        $good = 'sli:http_requests:rate5m{service="' + $label + '",status_class="2xx"}'
        $tot = 'sli:http_requests:rate5m{service="' + $label + '"}'
        $contQ = Expand-Query 'http_server_requests_total{service="%L%"}' @{ L = $label }
      }
      'Latency' {
        $mq = Expand-Query 'sum(increase(http_server_request_duration_seconds_bucket{service="%L%",le="0.3"}[%D%d])) / sum(increase(http_server_request_duration_seconds_count{service="%L%"}[%D%d]))' @{ L = $label; D = $LookbackDays }
        $good = 'sli:http_request_latency_good:rate5m{service="' + $label + '"}'
        $tot = 'sli:http_request_latency_total:rate5m{service="' + $label + '"}'
        $contQ = Expand-Query 'http_server_request_duration_seconds_count{service="%L%"}' @{ L = $label }
      }
      'Dependency' {
        $mq = Expand-Query 'sum(increase(dependency_calls_total{dependency="%L%",status="ok"}[%D%d])) / sum(increase(dependency_calls_total{dependency="%L%"}[%D%d]))' @{ L = $label; D = $LookbackDays }
        $good = 'sli:dependency_calls:rate5m{dependency="' + $label + '",status="ok"}'
        $tot = 'sli:dependency_calls:rate5m{dependency="' + $label + '"}'
        $contQ = Expand-Query 'dependency_calls_total{dependency="%L%"}' @{ L = $label }
      }
    }
    $measured = Get-PromScalar $mq
    $measuredPct = if ($null -ne $measured) { [math]::Round($measured * 100, 3) } else { $null }
    if ($null -ne $measuredPct) { Write-Good ("Measured ({0}d): {1}%" -f $LookbackDays, $measuredPct) }
    else { Write-Warn 'No data for the measurement window (need continuous traffic).' }

    # 4.3 Confirm the signal is continuous (no silent gaps).
    Write-Step '4.3 - Confirm the signal is continuous (no silent gaps)'
    Write-Info 'Checking the last 6h in 5m buckets...'
    $cq = "min_over_time( (sum(count_over_time($contQ[5m])) > bool 0)[6h:5m] )"
    $cont = Get-PromScalar $cq
    $continuous = ($cont -eq 1)
    if ($continuous) { Write-Good 'Continuous: yes (no empty 5m buckets).' }
    else { Write-Warn 'Gaps detected (a 5m bucket was empty). Keep steady traffic running.' }

    # 4.4 Write the good / valid definition (the contract).
    Write-Step '4.4 - Write the good / valid definition (the contract)'
    switch ($cat) {
      'Availability' { $defGood = "requests with status_class=2xx (service=$label)"; $defValid = "all requests with service=$label (exclude /healthz)" }
      'Latency' { $defGood = "requests completing in <= 0.3s (service=$label)"; $defValid = "all requests with service=$label" }
      'Dependency' { $defGood = "calls with status=ok (dependency=$label)"; $defValid = "all calls with dependency=$label" }
    }
    $goodDef = Read-WithDefault '  Good =' $defGood
    $validDef = Read-WithDefault '  Valid =' $defValid

    # 4.5 Data-collection worksheet (fill one per critical journey).
    Write-Step '4.5 - Data-collection worksheet (fill one per critical journey)'
    $defTarget = '99.5'
    if ($null -ne $measuredPct) {
      $budgetUsed = if ($measuredPct -lt 100) { [math]::Round((100 - $measuredPct) / (100 - [double]$defTarget), 2) } else { 0 }
      Write-Info ("At target {0}% the error budget is {1}% (currently ~{2}x used)." -f $defTarget, (100 - [double]$defTarget), $budgetUsed)
    }
    $target = Read-WithDefault '  Proposed SLO target %' $defTarget
    $window = Read-WithDefault '  Evaluation window (rolling days)' "$LookbackDays"

    # Default SLI name follows the demo convention.
    $suffixName = @{ Availability = 'AvailabilitySLI'; Latency = 'LatencySLI'; Dependency = 'DependencySLI' }[$cat]
    $defName = (ConvertTo-Title $label) + $suffixName
    $sliName = Read-WithDefault '  SLI name' $defName

    $script:Designs += [pscustomobject]@{
      Journey      = $c.Journey
      SliName      = $sliName
      Category     = $cat
      Label        = $label
      GoodSignal   = $good
      TotalSignal  = $tot
      GoodDef      = $goodDef
      ValidDef     = $validDef
      MeasuredPct  = $measuredPct
      TargetPct    = [double]$target
      WindowDays   = [int]$window
      BudgetPct    = [math]::Round(100 - [double]$target, 3)
      Continuous   = $continuous
    }
    Write-Good "Recorded worksheet for $sliName."
  }

  Pause-Phase 4
}

# ===========================================================================
# PHASE 5: Consolidate into the design checklist
# ===========================================================================
function Invoke-Phase5 {
  Write-Phase 5 'Consolidate into the design checklist'
  if (-not $script:Designs -or $script:Designs.Count -eq 0) { throw 'No designs from Phase 4.' }

  Write-Step '5.1 - Design checklist worksheet (one row per SLI)'
  Write-Info 'Burn-rate policy applied uniformly: fast burn ~14x / 1h (page), slow burn ~3x / 6h (ticket).'
  $view = $script:Designs | ForEach-Object {
    [pscustomobject]@{
      SLI       = $_.SliName
      Type      = $_.Category
      Target    = "$($_.TargetPct)%"
      Window    = "$($_.WindowDays)d"
      Budget    = "$($_.BudgetPct)%"
      FastBurn  = '~14x/1h'
      SlowBurn  = '~3x/6h'
      Good      = $_.GoodSignal
      Total     = $_.TotalSignal
    }
  }
  $view | Format-Table SLI, Type, Target, Window, Budget, FastBurn, SlowBurn -AutoSize | Out-Host

  $csv = Join-Path $PSScriptRoot 'design-checklist.csv'
  $script:Designs | Export-Csv -NoTypeInformation $csv
  Write-Good "Design checklist written to $csv."

  Write-Step '5.2 - Carry the row into the wizard'
  Write-Info 'Each checklist row maps to the Create-new-SLI wizard fields in Phase 6.'

  Pause-Phase 5
}

# ===========================================================================
# PHASE 6: Author the SLIs in the portal (optional automation)
# ===========================================================================
function Invoke-Phase6 {
  Write-Phase 6 'Author the SLIs in the portal'
  Write-Step '6.0 - Pre-flight (the form assumes these are already done)'
  Write-Info 'Needs: default Managed Identity + Azure Monitor Workspace on the Service Group, RBAC on the'
  Write-Info 'identity, and indexed metric dimensions. deploy-sli.ps1 wires these up automatically.'
  Write-Info 'SLI authoring is a portal wizard (Basics / SLI / Baseline + Alert / Review + create).'
  Write-Info 'For the demo scenario it is fully automated by infra/sli/deploy-sli.ps1 (recording rules,'
  Write-Info 'Service Group, membership, monitoring defaults, and the three SLIs).'

  $sloScript = Join-Path $PSScriptRoot 'infra/sli/deploy-sli.ps1'
  if (-not (Test-Path $sloScript)) {
    Write-Warn "deploy-sli.ps1 not found at $sloScript. Author the SLIs manually per Phase 6 of the lab."
    Pause-Phase 6
    return
  }

  # When the Service Group is absent, default to creating it (deploy-sli.ps1 is the
  # idempotent creator: recording rules, Service Group, membership, monitoring, SLIs).
  $needCreate = -not $script:SgExists
  if ($needCreate) {
    Write-Warn "Service Group '$($script:Sg)' is not present; deploy-sli.ps1 will CREATE it and author the SLIs."
  } else {
    Write-Info "Service Group '$($script:Sg)' already exists; deploy-sli.ps1 is idempotent and will reconcile the SLIs."
  }

  if (Confirm-Yes 'Run deploy-sli.ps1 now to create/author the Service Group and SLIs?' $needCreate) {
    Write-Step '6.1 to 6.5 - Author each SLI (Basics, SLI, Baseline + Alert, Review + create; repeat per SLI)'
    Write-Info 'Invoking deploy-sli.ps1...'
    & $sloScript -ResourceGroup $ResourceGroup -MainDeploymentName $MainDeploymentName -ServiceGroupName $script:Sg
    $script:SgExists = $true
    Write-Good 'deploy-sli.ps1 finished (re-run it if any SLI is still pending indexing).'
  } else {
    Write-Info 'Skipped. Author each checklist row in the portal, or run:'
    Write-Info ("  ./infra/sli/deploy-sli.ps1 -ResourceGroup {0} -ServiceGroupName {1}" -f $ResourceGroup, $script:Sg)
  }

  Pause-Phase 6
}

# ===========================================================================
# PHASE 7: Validate end-to-end
# ===========================================================================
function Invoke-Phase7 {
  Write-Phase 7 'Validate end-to-end'
  Write-Step '7.1 - Provisioning and execution state'
  Write-Info 'Check in the portal: Service Group > Monitoring > View all SLIs (Provisioning=Succeeded, execution=Running).'
  $sgLower = $script:Sg.ToLower()

  # Enumerate the SLIs authored on the Service Group from the control plane, so validation matches
  # what was actually authored (deploy-sli.ps1) rather than the in-memory design names. Managed
  # Prometheus only allows equality on __name__ (no regex discovery), so the SLI list is the
  # reliable source of names; we then confirm each one's published value by exact metric name.
  Write-Step '7.2 - Confirm the engine publishes results'
  $sliListUrl = "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$($script:Sg)/providers/Microsoft.Monitor/slis?api-version=2025-03-01-preview"
  $sliNames = @()
  try { $sliNames = @((az rest --method get --url $sliListUrl 2>$null | ConvertFrom-Json).value | ForEach-Object { $_.name }) } catch { $sliNames = @() }
  if (-not $sliNames -or $sliNames.Count -eq 0) {
    Write-Warn 'No SLIs found on the Service Group (control plane). Author them in Phase 6 first.'
    Pause-Phase 7
    return
  }
  Write-Good ("Authored SLIs: {0}" -f ($sliNames -join ', '))

  foreach ($sliName in $sliNames) {
    $sliLower = $sliName.ToLower()
    $base = "ns::$sgLower/m::$sliLower"
    Write-Host ''
    Write-Host ("---- {0} ----" -f $sliName) -ForegroundColor White

    $val = Get-PromScalar ('{__name__="' + $base + ':value"}')
    if ($null -eq $val) {
      Write-Warn 'No published :value series yet. The engine needs several evaluation cycles; portal columns lag 30-60 min further.'
      continue
    }
    $g = Get-PromScalar ('{__name__="' + $base + ':good"}')
    $t = Get-PromScalar ('{__name__="' + $base + ':total"}')
    Write-Good ("engine value = {0:n4}" -f $val)

    Write-Step '7.3 - Cross-check the engine against your own math'
    if ($g -and $t -and $t -ne 0) {
      $calc = 100 * $g / $t
      Write-Good ("100*good/total = {0:n4}  (internal consistency)" -f $calc)
    }

    # When a design row matches this SLI, recompute independently from the source recording rule.
    $design = $script:Designs | Where-Object { $_.SliName.ToLower() -eq $sliLower } | Select-Object -First 1
    if ($design) {
      $recompute = "clamp_max(100 * sum($($design.GoodSignal)) / sum($($design.TotalSignal)), 100)"
      $src = Get-PromScalar $recompute
      if ($null -ne $src) {
        $gap = [math]::Round([math]::Abs($val - $src), 4)
        Write-Good ("source recompute = {0:n4}  (gap {1} point)" -f $src, $gap)
        if ($gap -gt 0.5) { Write-Warn 'Gap > 0.5 point and persistent would warrant a look at filters / recording rule.' }
      }
    }
  }

  Pause-Phase 7
}

# ===========================================================================
# PHASE 8: Lab completion checklist
# ===========================================================================
function Invoke-Phase8 {
  Write-Phase 8 'Lab completion checklist'
  Write-Info 'Phase 1: PromQL (and App Insights) queries return data.'
  Write-Info 'Phase 2: every journey inventoried, gaps noted.'
  Write-Info 'Phase 3: 1 to 3 critical journeys extracted, each tagged with a category.'
  Write-Info 'Phase 4: dimensions confirmed, performance measured, continuity checked, good/valid written.'
  Write-Info 'Phase 5: a design-checklist row per SLI (target, window, budget, burn alerts).'
  Write-Info 'Phase 6: each row authored (portal or deploy-sli.ps1).'
  Write-Info 'Phase 7: each SLI publishes ns::.../m::...:value and matches your math.'
  Write-Host ''
  if ($script:Designs -and $script:Designs.Count -gt 0) {
    Write-Good ("Designed SLIs: {0}" -f (($script:Designs.SliName) -join ', '))
  }
  Write-Info 'Operate and iterate: review monthly. Loose target = budget never spent; tight target = always blown.'
}

# ===========================================================================
# Main
# ===========================================================================
if ($StartPhase -gt $EndPhase) { throw '-StartPhase must be <= -EndPhase.' }

Write-Host ''
Write-Host 'SLO / SLI Design Lab - interactive runner' -ForegroundColor Cyan
Write-Host ("Phases {0} to {1}{2}" -f $StartPhase, $EndPhase, ($(if ($script:NonInteractive) { ' (non-interactive)' } else { '' }))) -ForegroundColor DarkCyan

# Phase 1 always runs first when in range, because later phases need its context.
if ($StartPhase -gt 1) {
  Write-Warn 'Phases 2+ need the Phase 1 context (endpoint, helpers). Running Phase 1 setup first.'
  Invoke-Phase1
} elseif ($StartPhase -le 1 -and $EndPhase -ge 1) {
  Invoke-Phase1
}

if ($StartPhase -le 2 -and $EndPhase -ge 2) { Invoke-Phase2 }
if ($StartPhase -le 3 -and $EndPhase -ge 3) { Invoke-Phase3 }
if ($StartPhase -le 4 -and $EndPhase -ge 4) { Invoke-Phase4 }
if ($StartPhase -le 5 -and $EndPhase -ge 5) { Invoke-Phase5 }
if ($StartPhase -le 6 -and $EndPhase -ge 6) { Invoke-Phase6 }
if ($StartPhase -le 7 -and $EndPhase -ge 7) { Invoke-Phase7 }
if ($StartPhase -le 8 -and $EndPhase -ge 8) { Invoke-Phase8 }

# Optional cleanup: delete the Service Group and the SLIs inside it (teardown-slo.ps1).
# Recording rules and the Azure Monitor Workspace are left intact (they belong to the main deploy).
$teardownScript = Join-Path $PSScriptRoot 'infra/sli/teardown-slo.ps1'
if ((Test-Path $teardownScript) -and $script:Sg) {
  Write-Host ''
  Write-Step 'Cleanup (optional)'
  Write-Warn "This DELETES Service Group '$($script:Sg)' and its SLIs (recording rules and AMW are left intact)."
  # Always ask the human before this destructive step, even under -NonInteractive (deletion must be
  # an explicit choice). Default is No; a non-answer or no console leaves the Service Group in place.
  $ans = Read-Host ("Delete Service Group '{0}' and its SLIs now? (y/N)" -f $script:Sg)
  if ($ans -match '^(y|yes)$') {
    & $teardownScript -ResourceGroup $ResourceGroup -MainDeploymentName $MainDeploymentName -ServiceGroupName $script:Sg
    Write-Good 'Teardown complete.'
  } else {
    Write-Info 'Left in place. Delete later with:'
    Write-Info ("  ./infra/sli/teardown-slo.ps1 -ResourceGroup {0} -ServiceGroupName {1}" -f $ResourceGroup, $script:Sg)
  }
}

Write-Host ''
Write-Good 'Lab run complete.'
