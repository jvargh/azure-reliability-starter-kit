<#
.SYNOPSIS
  Interactive lab runner for the Azure SRE Agent phase: build (via the official IaC templates),
  validate it is up, and wire its inputs from the SLI demo and the Health Model. Teardown is a
  separate script (./teardown.ps1).

.DESCRIPTION
  Phase 2 of the reliability kit. The SRE Agent (Microsoft.App/agents) is deployed with the
  production templates from https://github.com/microsoft/sre-agent using the 'azmon-lawappinsights'
  recipe (Azure Monitor alert response + Log Analytics + Application Insights), scoped to the SLI and
  Health Model resource groups so the burn-rate and health-state alerts flow to the agent.

  Phases:
    1  Environment + access checks            (subscription, provider, region, RGs, alerts)
    2  Acquire the SRE Agent IaC templates     (git clone microsoft/sre-agent, prereqs)
    3  Generate the agent config from a recipe (New-Agent.ps1, azmon-lawappinsights)
    4  Deploy the agent                        (Deploy-Agent.ps1; -DryRun for what-if)
    5  Validate the agent is up                (poll Microsoft.App/agents provisioningState)
    6  Wire inputs from Health Model + SLI     (verify alerts, action group, agent target scope)

  Deleting the agent is intentionally NOT part of this runner. Use ./teardown.ps1 -DeleteResourceGroup.

.EXAMPLE
  ./sre-run-lab.ps1
.EXAMPLE
  ./sre-run-lab.ps1 -NonInteractive -DryRun
.EXAMPLE
  ./sre-run-lab.ps1 -StartPhase 5 -EndPhase 6   # validate + wire an already-deployed agent

.NOTES
  Requires PowerShell 7+, Azure CLI (signed in), git, and the recipe prerequisites (jq, Python 3 +
  PyYAML) which Phase 2 can install via the templates' Install-Prerequisites.ps1. Owner, or
  Contributor + User Access Administrator, on the subscription. SRE Agent regions: Sweden Central,
  East US 2, Australia East.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Subscription,

  # SRE Agent target.
  [string]$AgentName = 'sre-checkout',
  [string]$ResourceGroup = 'rg-sre-agent',
  [ValidateSet('swedencentral', 'eastus2', 'australiaeast')]
  [string]$Location = 'eastus2',
  [string]$Recipe = 'azmon-lawappinsights',

  # The workload the agent manages / ingests alerts from (becomes the recipe's targetRGs).
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$HealthModelResourceGroup = 'rg-healthmodel-demo',
  [string]$ActionGroupName = 'ag-sli-demo',

  # Official SRE Agent IaC templates. Point -TemplatesPath at an existing clone to skip cloning.
  [string]$TemplatesRepo = 'https://github.com/microsoft/sre-agent.git',
  [string]$TemplatesPath,

  # Deploy behaviour.
  [switch]$DryRun,          # pass what-if to Deploy-Agent (validate, do not deploy)
  [switch]$SkipPrereqs,     # skip the templates' Install-Prerequisites.ps1
  [switch]$SkipRepos,       # strip the placeholder GitHub repo so deploy never waits on OAuth
  [switch]$ShowBicepWarnings, # show the upstream templates' Bicep linter/compiler warnings during deploy

  [ValidateRange(1, 6)][int]$StartPhase = 1,
  [ValidateRange(1, 6)][int]$EndPhase = 6,
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:NonInteractive = [bool]$NonInteractive
$script:AgentResourceType = 'Microsoft.App/agents'
$script:ConfigDir = Join-Path $PSScriptRoot ".agent-config/$AgentName"
$script:TargetRgs = @($SliResourceGroup, $HealthModelResourceGroup)

# Default templates location so Phases 4-6 work when started standalone (Phase 2 skipped).
if ($TemplatesPath) {
  $script:Templates = if (Test-Path (Join-Path $TemplatesPath 'sreagent-templates')) { Join-Path $TemplatesPath 'sreagent-templates' } else { $TemplatesPath }
}
else {
  $script:Templates = Join-Path (Join-Path $PSScriptRoot '.sre-agent-templates') 'sreagent-templates'
}

# ---------------------------------------------------------------------------
# Presentation + input helpers (shared shape with ../02-healthmodel-demo/healthmodel-run-lab.ps1)
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
function Read-WithDefault([string]$Prompt, [string]$Default) {
  if ($script:NonInteractive) { return $Default }
  $suffix = if ($Default) { " [$Default]" } else { '' }
  $ans = Read-Host ("{0}{1}" -f $Prompt, $suffix)
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default } else { return $ans.Trim() }
}

# Resolve the SRE Agent resource (Microsoft.App/agents) in the target RG, or $null.
function Get-SreAgent {
  $sub = az account show --query id -o tsv 2>$null
  $id = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/$($script:AgentResourceType)/$AgentName"
  $a = az resource show --ids $id --api-version 2025-05-01-preview -o json 2>$null | ConvertFrom-Json
  return $a
}

# Data-plane endpoint (ARM .properties.agentEndpoint) and token (audience https://azuresre.dev).
function Get-AgentEndpoint {
  $a = Get-SreAgent
  if ($a) { return $a.properties.agentEndpoint }
  return $null
}
function Get-DpToken {
  return (az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null)
}

# The recipe generates a placeholder GitHub repo (empty url) that makes Deploy-Agent's data-plane
# step wait on an interactive OAuth browser sign-in. Removing it keeps deploy non-interactive; GitHub
# can be connected later in sre.azure.com > Repos. Auto-applied for -NonInteractive runs.
function Remove-ReposConfig {
  $reposDir = Join-Path $script:ConfigDir 'config/repos'
  if (Test-Path $reposDir) {
    $files = Get-ChildItem $reposDir -Filter *.yaml -ErrorAction SilentlyContinue
    if ($files) {
      $files | Remove-Item -Force
      Write-Info 'Removed placeholder GitHub repo config (skips OAuth; connect GitHub later in the portal).'
    }
  }
}

# Quiet the upstream Deploy-Agent.ps1 output that is noise for lab users:
#   1. the full 'az deployment' result JSON (hundreds of lines), and
#   2. its inline post-deploy verification table (redundant and it shows transient reds; this runner
#      runs its own authoritative verification at Phase 6.5).
# Idempotent line patches, re-applied each run after the templates are pulled (Phase 2 resets the
# clone before pulling so the fast-forward still succeeds).
function Hide-DeployNoise {
  $dep = Join-Path $script:Templates 'bin/ps/Deploy-Agent.ps1'
  if (-not (Test-Path $dep)) { return }
  $content = Get-Content $dep -Raw
  $orig = $content
  # 1. Suppress the raw 'az deployment' result JSON (hundreds of lines).
  $content = $content -replace '(?m)^(\s*)Write-Host \$deployJson\s*$', '$1# raw deployment JSON dump suppressed by sre-run-lab.ps1'
  # 2. Skip the redundant inline post-deploy verification (this runner verifies at Phase 6.5).
  #    Verify-Agent prints its table via its own Write-Host, so skip the INVOCATION, not just the echo.
  $content = $content -replace '(?m)^(\s*)Write-Header ''.*Post-deploy verification.*''\s*$', '$1# inline post-deploy verification header suppressed by sre-run-lab.ps1 (see Phase 6.5)'
  $content = $content -replace '(?m)^(\s*)\$VerifyOutput = & \$VerifyScript .*$', '$1# inline Verify-Agent call skipped by sre-run-lab.ps1 (authoritative check runs at Phase 6.5)'
  $content = $content -replace '(?m)^(\s*)\$VerifyOutput = bash \$verifyBash .*$', '$1# inline verify (bash) skipped by sre-run-lab.ps1 (see Phase 6.5)'
  $content = $content -replace '(?m)^(\s*)Write-Host \$VerifyOutput\s*$', '$1# inline verification table suppressed by sre-run-lab.ps1 (see Phase 6.5)'
  if ($content -ne $orig) {
    Set-Content -Path $dep -Value $content -Encoding utf8 -NoNewline
    Write-Info 'Quieted Deploy-Agent.ps1 (suppressed raw deployment JSON + redundant inline verification).'
  }
}

# Apply the recipe's response-plan incident filters via the data-plane, working around a template
# bug: azmon-*.yaml can carry a 'deepInvestigationEnabled' field the v2 IncidentFilter API rejects
# (HTTP 400 'could not be mapped'). We strip it before PUT so Deploy-Agent's failure self-heals.
function Invoke-ApplyIncidentFilters {
  $filterDir = Join-Path $script:ConfigDir 'automations/incident-filters'
  if (-not (Test-Path $filterDir)) { Write-Info 'No incident-filters in the config; nothing to apply.'; return }
  $files = Get-ChildItem $filterDir -Filter *.yaml -ErrorAction SilentlyContinue
  if (-not $files) { Write-Info 'No incident-filter yaml files found.'; return }

  $ep = Get-AgentEndpoint
  $tok = Get-DpToken
  if (-not $ep -or -not $tok) { Write-Warn 'Agent endpoint or data-plane token unavailable; skipping filter apply.'; return }

  $py = Get-Command python -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $obj = $null
    if ($py) {
      $json = python -c "import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))" $f.FullName 2>$null
      if ($json) { $obj = $json | ConvertFrom-Json }
    }
    if (-not $obj) { Write-Warn ("Could not parse {0} (needs python + PyYAML); skipping." -f $f.Name); continue }

    $name = $obj.metadata.name
    $spec = $obj.spec
    # Build properties from spec, dropping the unsupported field.
    $props = [ordered]@{}
    foreach ($p in $spec.PSObject.Properties) {
      if ($p.Name -eq 'deepInvestigationEnabled') { continue }
      $props[$p.Name] = $p.Value
    }
    if (-not $props.Contains('incidentPlatform')) { $props['incidentPlatform'] = 'AzMonitor' }
    if (-not $props.Contains('isEnabled')) { $props['isEnabled'] = $true }
    $body = @{ name = $name; type = 'IncidentFilter'; tags = @(); properties = $props } | ConvertTo-Json -Depth 20 -Compress
    $encoded = [uri]::EscapeDataString($name)
    $headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
    # The AzMonitor incident platform (set by the deploy's apply-extras ARM PATCH) can take a few
    # minutes to initialize, so the first PUT often fails right after deploy. Retry through that
    # window so the response plan reliably applies on a fresh run.
    $applied = $false
    for ($attempt = 1; $attempt -le 6 -and -not $applied; $attempt++) {
      try {
        $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$ep/api/v2/extendedAgent/incidentFilters/$encoded" -Method Put -Headers $headers -Body $body
        $applied = $true
        Write-Good ("Response plan applied: {0} (priorities {1} -> {2})" -f $name, ($spec.priorities -join '/'), $spec.handlingAgent)
      }
      catch {
        $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
        if ($attempt -lt 6) {
          Write-Info ("response plan '{0}' - retry {1}/5 in 30s (incident platform initializing)..." -f $name, $attempt)
          Start-Sleep -Seconds 30
        }
        else {
          Write-Warn ("Failed to apply response plan '{0}' after retries: {1}" -f $name, $msg)
        }
      }
    }
  }
}

# ===========================================================================
# PHASE 1: Environment + access checks
# ===========================================================================
function Invoke-Phase1 {
  Write-Phase 1 'Environment and access checks'

  Write-Step '1.1 - Subscription'
  if ($Subscription) { az account set --subscription $Subscription | Out-Null }
  $acct = az account show -o json | ConvertFrom-Json
  Write-Info ("Subscription : {0} ({1})" -f $acct.name, $acct.id)

  Write-Step '1.2 - Register resource provider Microsoft.App (required for the SRE Agent)'
  az provider register --namespace Microsoft.App -o none
  $state = az provider show --namespace Microsoft.App --query registrationState -o tsv
  Write-Info "Microsoft.App: $state"

  Write-Step '1.3 - Confirm the workload resource groups exist'
  foreach ($rg in $script:TargetRgs) {
    if ((az group exists -n $rg) -eq 'true') { Write-Good "$rg found." }
    else { Write-Warn "$rg NOT found (deploy ../01-sli-demo and ../02-healthmodel-demo first)." }
  }

  Write-Step '1.4 - Confirm the trigger alerts the agent will ingest'
  foreach ($rg in $script:TargetRgs) {
    $alerts = @(az monitor metrics alert list -g $rg --query "[].name" -o tsv 2>$null | Where-Object { $_ })
    Write-Info ("{0}: {1} metric alert rule(s)" -f $rg, $alerts.Count)
  }
  Write-Info 'These SLI burn-rate + Health Model health-state alerts are the SRE Agent triggers.'

  Write-Step '1.5 - Choose the SRE Agent to create or reuse'
  Write-Info 'The SRE Agent (Microsoft.App/agents) region is limited to swedencentral, eastus2, australiaeast.'

  # Discover existing SRE Agents in the subscription so one can be reused by selection instead of
  # retyping its name / resource group / region (mirrors the health model lab's Phase 1.6).
  $existingAgents = @()
  try { $existingAgents = @(az resource list --resource-type $script:AgentResourceType --query "[].{name:name, rg:resourceGroup, loc:location}" -o json 2>$null | ConvertFrom-Json) } catch { $existingAgents = @() }
  $regions = @('swedencentral', 'eastus2', 'australiaeast')

  while ($true) {
    if (-not $script:NonInteractive) {
      $picked = $false
      if ($existingAgents.Count -gt 0) {
        Write-Info 'Existing SRE Agents in this subscription (select one to reuse, or create new):'
        for ($i = 0; $i -lt $existingAgents.Count; $i++) {
          Write-Info ("  [{0}] {1}  ({2} / {3})" -f $i, $existingAgents[$i].name, $existingAgents[$i].rg, $existingAgents[$i].loc)
        }
        Write-Info '  [n] Create a new SRE Agent'
        $sel = Read-WithDefault 'Select an agent number to reuse, or n to create new' 'n'
        [int]$idx = -1
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $existingAgents.Count) {
          $script:AgentName = $existingAgents[$idx].name
          $script:ResourceGroup = $existingAgents[$idx].rg
          $script:Location = $existingAgents[$idx].loc
          $picked = $true
        }
      }
      else {
        Write-Info 'No existing SRE Agents found in this subscription; creating a new one.'
      }
      if (-not $picked) {
        Write-Info 'New SRE Agent (press Enter to accept each default):'
        $script:AgentName = Read-WithDefault 'Agent name' $AgentName
        $script:ResourceGroup = Read-WithDefault 'Agent resource group' $ResourceGroup
        do {
          $region = Read-WithDefault 'Agent region (swedencentral/eastus2/australiaeast)' $Location
          if ($region -notin $regions) { Write-Warn ("Region must be one of: {0}." -f ($regions -join ', ')) }
        } until ($region -in $regions)
        $script:Location = $region
      }
    }

    # Recompute the per-agent config directory for the chosen name.
    $script:ConfigDir = Join-Path $PSScriptRoot ".agent-config/$($script:AgentName)"
    $agentState = if (Get-SreAgent) { 'exists (Phase 4 reconciles it)' } else { 'new (Phase 4 creates it)' }

    Write-Host ''
    Write-Host '  Confirmed configuration:' -ForegroundColor White
    [pscustomobject]@{
      Subscription = $acct.id
      Agent        = $script:AgentName
      AgentRG      = $script:ResourceGroup
      Region       = $script:Location
      AgentState   = $agentState
      Recipe       = $Recipe
      TargetRGs    = ($script:TargetRgs -join ', ')
      ActionGroup  = $ActionGroupName
    } | Format-List | Out-Host

    if (Confirm-Yes 'Proceed with these values?' $true) { break }
    if ($script:NonInteractive) { break }
    if (-not (Confirm-Yes 'Choose again (select a different agent or create new)?' $true)) {
      Write-Warn 'Aborted at the confirmation step. No changes were made.'
      exit 1
    }
  }

  Pause-Phase 1
}

# ===========================================================================
# PHASE 2: Acquire the SRE Agent IaC templates
# ===========================================================================
function Invoke-Phase2 {
  Write-Phase 2 'Acquire the SRE Agent IaC templates'
  Write-Info 'Uses the production templates from microsoft/sre-agent (Bicep, PowerShell backend).'

  if (-not $TemplatesPath) {
    $clone = Join-Path $PSScriptRoot '.sre-agent-templates'
    if (Test-Path (Join-Path $clone '.git')) {
      Write-Step '2.1 - Updating existing templates clone'
      # Discard our local Hide-DeployNoise patch so the fast-forward pull always succeeds; re-applied below.
      git -C $clone checkout -- . 2>&1 | Out-Null
      git -C $clone pull --ff-only 2>&1 | Out-Null
    }
    else {
      Write-Step "2.1 - Cloning $TemplatesRepo"
      git clone --depth 1 $TemplatesRepo $clone 2>&1 | Out-Null
    }
    $script:Templates = Join-Path $clone 'sreagent-templates'
  }
  else {
    $script:Templates = if (Test-Path (Join-Path $TemplatesPath 'sreagent-templates')) { Join-Path $TemplatesPath 'sreagent-templates' } else { $TemplatesPath }
  }
  if (-not (Test-Path (Join-Path $script:Templates 'bin/ps/New-Agent.ps1'))) {
    throw "SRE Agent templates not found under '$($script:Templates)'. Pass -TemplatesPath to a clone of microsoft/sre-agent."
  }
  Write-Good "Templates: $($script:Templates)"
  Hide-DeployNoise

  if (-not $SkipPrereqs) {
    Write-Step '2.2 - Installing recipe prerequisites (jq, Python + PyYAML)'
    $prereq = Join-Path $script:Templates 'bin/ps/Install-Prerequisites.ps1'
    if (Test-Path $prereq) { try { & $prereq } catch { Write-Warn "prereq install reported: $($_.Exception.Message)" } }
    else { Write-Warn 'Install-Prerequisites.ps1 not found; ensure jq and Python 3 + PyYAML are installed.' }
  }

  Pause-Phase 2
}

# ===========================================================================
# PHASE 3: Generate the agent config from the recipe
# ===========================================================================
function Invoke-Phase3 {
  Write-Phase 3 'Generate the agent config from the recipe'
  Write-Info "Recipe '$Recipe' wires Azure Monitor alert response with Log Analytics + App Insights."

  $newAgent = Join-Path $script:Templates 'bin/ps/New-Agent.ps1'
  if (-not (Test-Path $newAgent)) { throw "New-Agent.ps1 not found. Run Phase 2 first." }

  if (Confirm-Yes "Generate config into $($script:ConfigDir)?" $true) {
    Write-Step '3.1 - New-Agent.ps1'
    # Start clean: if this agent name was used before (e.g. torn down and recreated with the same
    # name), remove the previous run's generated config so no stale state from a prior agent is
    # carried into this deploy. A newly created agent is always fully independent.
    if (Test-Path $script:ConfigDir) {
      Write-Info 'Removing stale config from a previous run for this agent name (fresh generation).'
      Remove-Item -Recurse -Force $script:ConfigDir
    }
    $set = @{
      agentName     = $AgentName
      resourceGroup = $ResourceGroup
      location      = $Location
      targetRGs     = ($script:TargetRgs -join ',')
    }
    & $newAgent -Recipe $Recipe -NonInteractive -Set $set -Output $script:ConfigDir
    # This lab does not deploy the optional app-insights / log-analytics connectors (they are
    # investigation context, not needed for AzMonitor alert pickup, and the recipe disables them
    # unless you pass workspace ids). expected-config.json is used ONLY by the verifier, not the
    # deploy, so clear its connectors here to keep the final Phase 6 verification truthful and green.
    $expectedCfg = Join-Path $script:ConfigDir 'expected-config.json'
    if (Test-Path $expectedCfg) {
      try {
        $ec = Get-Content $expectedCfg -Raw | ConvertFrom-Json
        if (($ec.PSObject.Properties.Name -contains 'connectors') -and (@($ec.connectors).Count -gt 0)) {
          $ec.connectors = @()
          ($ec | ConvertTo-Json -Depth 20) | Set-Content -Path $expectedCfg -Encoding utf8
          Write-Info 'Cleared expected connectors (not deployed by this lab; keeps the final verification truthful).'
        }
      }
      catch { Write-Warn "Could not adjust expected connectors: $($_.Exception.Message)" }
    }
    # Bake in a common prompt that stops the agent writing incident learnings to its memory files.
    # The SRE Agent's auto-learning (session insights -> debugging.md) has no API/config toggle, so this
    # behavioral directive is the supported lever. It also tells the agent to fully remediate every alert
    # even when memory shows a similar past incident (so recurrences are never short-circuited).
    $cpDir = Join-Path $script:ConfigDir 'config/common-prompts'
    if (Test-Path $cpDir) {
      $memPolicy = @(
        'metadata:'
        '  name: memory-write-policy'
        'spec:'
        '  prompt: |-'
        '    ## Memory write policy'
        ''
        '    - Do not update or write to memory files after incident remediation.'
        '    - For every fired alert, always perform the full investigation, remediation, and recovery'
        '      verification, even if memory shows a similar or recurring past incident. Treat memory as'
        '      context only; never skip or defer remediation because an incident looks familiar.'
      ) -join "`n"
      Set-Content -Path (Join-Path $cpDir 'memory-write-policy.yaml') -Value $memPolicy -Encoding utf8
      # Declare it in expected-config.json so the Phase 6 verifier stays truthful/green.
      if (Test-Path $expectedCfg) {
        try {
          $ec2 = Get-Content $expectedCfg -Raw | ConvertFrom-Json
          $cps = [System.Collections.Generic.List[string]]::new()
          if ($ec2.PSObject.Properties.Name -contains 'commonPrompts') { $ec2.commonPrompts | ForEach-Object { $cps.Add($_) } }
          if (-not $cps.Contains('memory-write-policy')) { $cps.Add('memory-write-policy') }
          $ec2.commonPrompts = $cps
          ($ec2 | ConvertTo-Json -Depth 20) | Set-Content -Path $expectedCfg -Encoding utf8
        }
        catch { Write-Warn "Could not register memory-write-policy in expected-config: $($_.Exception.Message)" }
      }
      Write-Good 'Added common prompt: memory-write-policy (no memory writes + always remediate).'
    }
    Write-Good "Config written to $($script:ConfigDir)"
    Write-Info 'Review agent.json / connectors.json / roles.yaml before deploying to customize the agent.'
  }
  else { Write-Info 'Skipped config generation.' }

  Pause-Phase 3
}

# ===========================================================================
# PHASE 4: Deploy the agent
# ===========================================================================
function Invoke-Phase4 {
  Write-Phase 4 'Deploy the agent'
  Write-Info 'Deploys the resource group, managed identity, Log Analytics, App Insights, the SRE Agent'
  Write-Info '(Microsoft.App/agents), and RBAC on the target resource groups.'

  $deploy = Join-Path $script:Templates 'bin/ps/Deploy-Agent.ps1'
  if (-not (Test-Path $deploy)) { throw "Deploy-Agent.ps1 not found. Run Phase 2 first." }
  if (-not (Test-Path $script:ConfigDir)) { throw "Config dir '$($script:ConfigDir)' not found. Run Phase 3 first." }

  $label = if ($DryRun) { 'what-if (no changes)' } else { 'deploy' }
  if (Confirm-Yes "Run Deploy-Agent.ps1 now ($label)?" (-not $DryRun)) {
    if ($SkipRepos -or $script:NonInteractive) { Remove-ReposConfig }
    Write-Step '4.1 - Deploy-Agent.ps1'
    $splat = @{ InputPath = $script:ConfigDir }
    if ($DryRun -and (Get-Command $deploy).Parameters.ContainsKey('WhatIf')) { $splat.WhatIf = $true }
    # The upstream microsoft/sre-agent Bicep templates emit harmless linter/compiler warnings
    # (BCP081 preview-type-not-available, BCP318 possible-null, no-unused-params/vars,
    # outputs-should-not-contain-secrets) plus a Bicep version nag during 'az deployment'. None block
    # the deploy. They are all WARNING level, so Azure CLI only-show-errors mode hides them while the
    # template's own Write-Host progress banners still print. Pass -ShowBicepWarnings to see them.
    $prevOnlyErr = $env:AZURE_CORE_ONLY_SHOW_ERRORS
    if (-not $ShowBicepWarnings) {
      $env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
      Write-Info 'Suppressing upstream Bicep template warnings (pass -ShowBicepWarnings to see them).'
    }
    try {
      & $deploy @splat
    }
    finally {
      if (-not $ShowBicepWarnings) {
        if ($null -eq $prevOnlyErr) { Remove-Item Env:AZURE_CORE_ONLY_SHOW_ERRORS -ErrorAction SilentlyContinue }
        else { $env:AZURE_CORE_ONLY_SHOW_ERRORS = $prevOnlyErr }
      }
    }
    if ($DryRun) { Write-Info 'What-if only; no resources changed.' }
    if (-not $DryRun) {
      Write-Info 'The post-deploy verification above is the template''s own snapshot taken right after deploy.'
      Write-Info 'The authoritative check runs at the end of Phase 6 (step 6.5), after all config is applied:'
      Write-Info '  - Response Plans (azmon-sev01): applied with retry in Phase 6 (6.4) once the platform initializes.'
      Write-Info '  - Connectors: not deployed by this lab (optional); the expectation is cleared so the final check is green.'
    }
  }
  else { Write-Info 'Skipped deploy.' }

  Pause-Phase 4
}

# ===========================================================================
# PHASE 5: Validate the agent is up
# ===========================================================================
function Invoke-Phase5 {
  Write-Phase 5 'Validate the agent is up'

  Write-Step '5.1 - Locate the SRE Agent resource'
  $agent = $null
  for ($i = 1; $i -le 10; $i++) {
    $agent = Get-SreAgent
    if ($agent -and $agent.properties.provisioningState -eq 'Succeeded') { break }
    if ($agent) { Write-Info ("provisioningState = {0} (waiting)" -f $agent.properties.provisioningState) }
    else { Write-Info 'agent not visible yet (waiting)' }
    if ($i -ge 10 -or $script:NonInteractive) { break }
    if (-not (Confirm-Yes 'Re-check in a moment?' $true)) { break }
  }

  if (-not $agent) {
    Write-Warn "SRE Agent '$AgentName' not found in '$ResourceGroup'. If you deployed via the portal or another RG, pass -ResourceGroup/-AgentName."
    Pause-Phase 5; return
  }
  $script:AgentId = $agent.id
  Write-Good ("Agent: {0}" -f $agent.name)
  Write-Info ("Provisioning state : {0}" -f $agent.properties.provisioningState)
  Write-Info ("Resource id        : {0}" -f $agent.id)
  Write-Info ("Portal   : https://sre.azure.com/#/agent/{0}/{1}/{2}" -f (az account show --query id -o tsv), $ResourceGroup, $AgentName)
  Write-Info ("Data plane: {0}" -f $agent.properties.agentEndpoint)
  if ($agent.properties.provisioningState -ne 'Succeeded') { Write-Warn 'Not fully provisioned yet; re-run Phase 5 shortly.' }

  Write-Info 'Deep data-plane verification (skills, subagents, hooks, response plans) runs at the end of'
  Write-Info 'Phase 6 (step 6.5), after all config is applied, so it reflects the final state.'

  Pause-Phase 5
}

# ===========================================================================
# PHASE 6: Wire inputs from Health Model + SLI
# ===========================================================================
function Invoke-Phase6 {
  Write-Phase 6 'Wire inputs from Health Model and SLI'
  Write-Info 'The agent ingests Azure Monitor alerts on its target resource groups. This confirms the'
  Write-Info 'SLI burn-rate and Health Model health-state alerts exist, are enabled, and notify the action group.'

  Write-Step '6.1 - Alerts on the target resource groups'
  $anyAlerts = $false
  foreach ($rg in $script:TargetRgs) {
    $alerts = az monitor metrics alert list -g $rg --query "[].{name:name, enabled:enabled, sev:severity}" -o json 2>$null | ConvertFrom-Json
    if ($alerts) {
      $anyAlerts = $true
      foreach ($a in $alerts) { Write-Info ("{0}: [{1}] Sev{2}  {3}" -f $rg, $(if ($a.enabled) { 'on' } else { 'off' }), $a.sev, $a.name) }
    }
    else { Write-Warn ("{0}: no metric alert rules (author SLI burn alerts / Health Model health-state alerts first)." -f $rg) }
  }

  Write-Step '6.2 - Action Group (human notification path)'
  $agId = az monitor action-group show -g $SliResourceGroup -n $ActionGroupName --query id -o tsv 2>$null
  if ($agId) { Write-Good "$ActionGroupName present: $agId" }
  else {
    Write-Warn "$ActionGroupName not found in $SliResourceGroup."
    if (Confirm-Yes "Create action group '$ActionGroupName' now?" $true) {
      az monitor action-group create -g $SliResourceGroup -n $ActionGroupName --short-name sreDemo -o none
      Write-Good "Created $ActionGroupName."
    }
  }

  Write-Step '6.3 - Confirm the agent target scope covers both resource groups'
  if (-not $script:AgentId) { $a = Get-SreAgent; if ($a) { $script:AgentId = $a.id } }
  Write-Info ("Recipe targetRGs deployed with: {0}" -f ($script:TargetRgs -join ', '))
  Write-Info 'Verify in sre.azure.com > agent > Managed resources that both RGs are listed; add any missing from Settings.'
  Write-Info 'Then connect Azure Monitor Alerts as the incident source and GitHub for deploy correlation (portal).'

  Write-Step '6.4 - Apply response plans (incident filters) so alerts are auto-handled'
  Write-Info 'Retries until the AzMonitor incident platform has initialized (can take a few minutes).'
  Invoke-ApplyIncidentFilters

  Write-Step '6.5 - Final data-plane verification (all config applied)'
  $verify = Join-Path $script:Templates 'bin/ps/Verify-Agent.ps1'
  if (Test-Path $verify) {
    $sub = az account show --query id -o tsv
    & $verify -Subscription $sub -ResourceGroup $ResourceGroup -AgentName $AgentName -Expected $script:ConfigDir
  }
  else { Write-Warn 'Verify-Agent.ps1 not found under the templates; skipping deep verification.' }

  Write-Step '6.6 - Upload knowledge (app topology + all remediation runbooks)'
  Write-Info 'Uploads the topology/common-cause doc and every src/remediation-runbooks/*.ps1 (as indexed'
  Write-Info 'knowledge docs) so the agent knows the layout and mitigations up front, from scratch.'
  $uploadKnowledge = Join-Path $PSScriptRoot 'upload-knowledge.ps1'
  $knowledgeDir = Join-Path $PSScriptRoot 'knowledge'
  if ((Test-Path $uploadKnowledge) -and (Test-Path $knowledgeDir)) {
    $sub = az account show --query id -o tsv
    try { & $uploadKnowledge -Subscription $sub -ResourceGroup $ResourceGroup -AgentName $AgentName -KnowledgeDir $knowledgeDir }
    catch { Write-Warn "Knowledge upload skipped: $($_.Exception.Message)" }
  }
  else { Write-Warn 'upload-knowledge.ps1 or knowledge/ folder not found; skipping knowledge upload.' }

  if (-not $anyAlerts) { Write-Warn 'No metric alert rules yet. Drive the SRE Agent with ./sli-alert-scenario.ps1 (creates the sli-fast-alerts trigger + injects a fault).' }

  Pause-Phase 6
}

# ===========================================================================
# Main
# ===========================================================================
if ($StartPhase -gt $EndPhase) { throw '-StartPhase must be <= -EndPhase.' }

Write-Host ''
Write-Host 'SRE Agent Lab - interactive runner' -ForegroundColor Cyan
Write-Host ("Phases {0} to {1}{2}" -f $StartPhase, $EndPhase, ($(if ($script:NonInteractive) { ' (non-interactive)' } else { '' }))) -ForegroundColor DarkCyan

if ($StartPhase -gt 1) { Write-Warn 'Later phases need the Phase 1 context. Running Phase 1 first.'; Invoke-Phase1 }
elseif ($EndPhase -ge 1) { Invoke-Phase1 }
if ($StartPhase -le 2 -and $EndPhase -ge 2) { Invoke-Phase2 }
if ($StartPhase -le 3 -and $EndPhase -ge 3) { Invoke-Phase3 }
if ($StartPhase -le 4 -and $EndPhase -ge 4) { Invoke-Phase4 }
if ($StartPhase -le 5 -and $EndPhase -ge 5) { Invoke-Phase5 }
if ($StartPhase -le 6 -and $EndPhase -ge 6) { Invoke-Phase6 }

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Host '  Lab completion checklist' -ForegroundColor Cyan
Write-Host ('=' * 78) -ForegroundColor DarkCyan
Write-Info 'Phase 1: environment resolved, provider registered, alerts present.'
Write-Info 'Phase 2: SRE Agent IaC templates acquired.'
Write-Info 'Phase 3: agent config generated from the azmon-lawappinsights recipe.'
Write-Info 'Phase 4: agent deployed (Microsoft.App/agents + identity + LAW + App Insights + RBAC).'
Write-Info 'Phase 5: agent provisioning state confirmed Succeeded.'
Write-Info 'Phase 6: SLI + Health Model alerts verified; action group + target scope confirmed.'
Write-Info 'Operate: connect Azure Monitor Alerts + GitHub in sre.azure.com, then test with ./sli-alert-scenario.ps1.'
Write-Host ''
Write-Info ("Delete later with:  ./teardown.ps1 -ResourceGroup {0} -AgentName {1}" -f $ResourceGroup, $AgentName)
Write-Info ("                    ./teardown.ps1 -ResourceGroup {0} -AgentName {1} -DeleteResourceGroup" -f $ResourceGroup, $AgentName)
Write-Host ''
Write-Good 'Lab run complete.'
