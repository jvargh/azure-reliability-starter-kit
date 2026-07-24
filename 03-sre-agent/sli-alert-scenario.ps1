<#
.SYNOPSIS
  Drive the "Checkout availability regression" scenario so the Azure SRE Agent ingests a Sev1 alert
  and autonomously remediates the root cause.

.DESCRIPTION
  Run this AFTER sre-run-lab.ps1 has deployed the agent (sre-checkout) scoped to rg-sli-demo.

  It creates the PROVEN SRE-Agent trigger: a fast Sev1 Prometheus alert (rule group 'sli-fast-alerts')
  on the SLI recording rule (sli:http_requests:rate5m), scoped to the AMW in rg-sli-demo. The agent's
  Azure Monitor incident source ingests alerts from rg-sli-demo, so this fires and the agent opens an
  investigation (verified: alert fires ~2-3 min after the fault, agent picks it up ~1 min later,
  Autonomous). With the uploaded knowledge base + Owner RBAC it resets the chaos and verifies recovery.

  NOTE: the SLI's "linked" metric alerts (on the SLI blade) do NOT fire and are display-only. Health
  Model alerts (rg-healthmodel-demo) are NOT ingested by the agent. This Prometheus alert is the trigger.

  Flow (default): create the alert -> start traffic -> inject chaos on checkout -> wait for it to fire
  -> hand off to the agent. Watch it in sre.azure.com > Incidents.

.PARAMETER EnableOnly
  Only create the trigger alert; do not inject a fault.

.PARAMETER TeardownAlert
  Remove the trigger alert, reset chaos, and stop the traffic job started by this script.

.EXAMPLE
  ./sli-alert-scenario.ps1                 # run the Checkout scenario
  ./sli-alert-scenario.ps1 -EnableOnly     # just create the trigger alert
  ./sli-alert-scenario.ps1 -TeardownAlert  # remove the alert + reset the fault
#>
param(
  [string]$Subscription,
  [string]$SliResourceGroup = 'rg-sli-demo',
  [string]$AgentResourceGroup = 'rg-sre-checkout',
  [string]$AgentName = 'sre-checkout',

  [string]$Service = 'checkout',
  [ValidateRange(1, 100)][double]$Threshold = 95,   # availability percent that trips the alert
  [ValidateRange(0, 4)][int]$Severity = 1,          # Sev1 matches the azmon-sev01 response plan
  [ValidateRange(0.05, 1)][double]$ErrorRate = 0.30,
  [int]$Rps = 30,
  [string]$ActionGroupName = 'ag-sli-demo',

  [int]$WatchMinutes = 12,
  [switch]$EnableOnly,
  [switch]$TeardownAlert,
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$AlertName = "${Service}AvailabilityFastBreach"
$RuleGroupBaseName = 'sli-fast-alerts'

function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Info([string]$m) { Write-Host "    $m" }
function Write-Good([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }
function Log([string]$m) { Write-Host ("    [{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

if ($Subscription) { az account set --subscription $Subscription | Out-Null }
$sub = az account show --query id -o tsv

# ---------------------------------------------------------------------------
# Resolve the workload resources (AMW, action group, backend) in rg-sli-demo.
# ---------------------------------------------------------------------------
$amwId = az resource list -g $SliResourceGroup --resource-type Microsoft.Monitor/accounts --query "[0].id" -o tsv
if (-not $amwId) { throw "No Azure Monitor Workspace found in $SliResourceGroup. Deploy ../01-sli-demo first." }
$amwLoc = az resource show --ids $amwId --query location -o tsv
$rgApi = '2023-03-01'

# Trigger alerts get a UNIQUE name per run so the SRE Agent opens a NEW incident each time.
# A same-named alert is treated as a REACTIVATION of the already-completed incident, not a fresh
# investigation. This helper removes this run family's rule groups (prior runs) for a clean slate.
function Remove-TriggerRuleGroups {
  $groups = az rest --method get --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$SliResourceGroup/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=$rgApi" -o json 2>$null | ConvertFrom-Json
  foreach ($g in ($groups.value | Where-Object { $_.name -like "$RuleGroupBaseName*" })) {
    az rest --method delete --url "https://management.azure.com$($g.id)?api-version=$rgApi" -o none 2>$null
  }
}

# ---------------------------------------------------------------------------
# Teardown mode: remove the alert rule, reset the fault, stop our traffic job.
# ---------------------------------------------------------------------------
if ($TeardownAlert) {
  Write-Step "Resetting the fault, stopping traffic, and removing the trigger alert(s)"
  Remove-TriggerRuleGroups
  $beHost = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].defaultHostName | [0]" -o tsv
  if ($beHost) {
    try { Invoke-RestMethod -Method Post "https://$beHost/admin/chaos" -Body (@{ service = $Service; errorRate = 0; extraLatencyMs = 0 } | ConvertTo-Json) -ContentType 'application/json' | Out-Null; Write-Good "Chaos reset on $Service." } catch { Write-Warn "Could not reset chaos: $($_.Exception.Message)" }
  }
  Get-Job -Name 'sli-scenario-traffic' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }
  Write-Good "Teardown complete (alerts removed, chaos reset, traffic stopped)."
  return
}

$agId = az monitor action-group show -g $SliResourceGroup -n $ActionGroupName --query id -o tsv 2>$null
$beHost = az webapp list -g $SliResourceGroup --query "[?contains(name,'-be-')].defaultHostName | [0]" -o tsv
if (-not $beHost) { throw "No backend App Service (*-be-*) found in $SliResourceGroup." }
$backend = "https://$beHost"

Write-Host ''
Write-Host '=================== SLI alert -> SRE Agent scenario ===================' -ForegroundColor DarkCyan
Write-Info "Subscription : $sub"
Write-Info "AMW          : $amwId ($amwLoc)"
Write-Info "Action group : $(if ($agId) { $agId } else { '(none - human notification will be skipped)' })"
Write-Info "Backend      : $backend"
Write-Info "Agent        : $AgentName ($AgentResourceGroup)"
Write-Info "Alert        : $RuleGroupBaseName-<run> / $AlertName  (Sev$Severity, ${Service} availability < ${Threshold}%; unique per run)"
Write-Host '======================================================================' -ForegroundColor DarkCyan

# ---------------------------------------------------------------------------
# 0. Reset any leftover state from a previous run (clean baseline).
#    A fresh run should not inherit prior chaos, a still-running traffic job, or old
#    trigger alerts, so each run starts clean. Use -TeardownAlert to reset + exit.
# ---------------------------------------------------------------------------
Write-Step "0 - Reset leftover state from any previous run"
Get-Job -Name 'sli-scenario-traffic' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }
Remove-TriggerRuleGroups
try { Invoke-RestMethod -Method Post "$backend/admin/chaos" -Body (@{ service = $Service; errorRate = 0; extraLatencyMs = 0 } | ConvertTo-Json) -ContentType 'application/json' | Out-Null; Write-Good "Prior chaos cleared, stale traffic stopped, and old trigger alerts removed." } catch { Write-Warn "Could not reset prior chaos: $($_.Exception.Message)" }

# ---------------------------------------------------------------------------
# 1. Create the fast SRE-Agent trigger alert (Prometheus rule on the AMW).
#    PROVEN trigger: a Sev1 Prometheus alert on the SLI recording rule, in rg-sli-demo.
#    The agent's Azure Monitor incident source ingests it (verified: fires ~2-3 min
#    after the fault, agent opens an Autonomous investigation ~1 min later).
# ---------------------------------------------------------------------------
Write-Step "1 - Create the fast SRE-Agent trigger alert (unique name per run)"
$RuleGroupName = "$RuleGroupBaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$ruleUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$SliResourceGroup/providers/Microsoft.AlertsManagement/prometheusRuleGroups/$RuleGroupName`?api-version=$rgApi"
$expr = ('100 * sum(sli:http_requests:rate5m{{service="{0}",status_class="2xx"}}) / sum(sli:http_requests:rate5m{{service="{0}"}}) < {1}' -f $Service, $Threshold)
$ruleProps = [ordered]@{
  description = "Fast SLI availability alert for $Service (SRE Agent trigger)."
  scopes      = @($amwId)
  enabled     = $true
  interval    = 'PT1M'
  rules       = @(
    [ordered]@{
      alert                = $AlertName
      expression           = $expr
      for                  = 'PT1M'
      severity             = $Severity
      labels               = @{ service = $Service; signal = 'sli-availability' }
      annotations          = @{ summary = "$Service availability below $Threshold% (fast SLI breach)" }
      resolveConfiguration = @{ autoResolved = $true; timeToResolve = 'PT5M' }
    }
  )
}
if ($agId) { $ruleProps.rules[0].actions = @(@{ actionGroupId = $agId }) }
$body = @{ location = $amwLoc; properties = $ruleProps }
$tmp = New-TemporaryFile
($body | ConvertTo-Json -Depth 12) | Set-Content -Path $tmp -Encoding utf8
az rest --method put --url $ruleUrl --headers 'Content-Type=application/json' --body "@$tmp" -o none
Remove-Item $tmp -Force
Write-Good "Alert '$RuleGroupName/$AlertName' created (Sev$Severity; unique name = new SRE-A incident). Auto-resolves ~5m after recovery."

if ($EnableOnly) {
  Write-Info 'EnableOnly set: alert is live. Inject a fault yourself to trigger the agent, e.g.:'
  Write-Info "  Invoke-RestMethod -Method Post $backend/admin/chaos -Body (@{service='$Service';errorRate=$ErrorRate;extraLatencyMs=0}|ConvertTo-Json) -ContentType application/json"
  return
}

# ---------------------------------------------------------------------------
# 2. Start traffic so the SLI signal has data.
# ---------------------------------------------------------------------------
Write-Step "2 - Start traffic against the workload"
$gen = (Resolve-Path (Join-Path $PSScriptRoot '../01-sli-demo/load/generate-traffic-all.ps1')).Path
$dur = ($WatchMinutes + 5) * 60
Get-Job -Name 'sli-scenario-traffic' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }
$job = Start-Job -Name 'sli-scenario-traffic' -ScriptBlock { param($g, $rg, $rps, $d) pwsh -NoProfile -File $g -ResourceGroup $rg -Rps $rps -DurationSeconds $d } -ArgumentList $gen, $SliResourceGroup, $Rps, $dur
Log "Traffic job '$($job.Name)' started (~$Rps rps). Warming up 90s so the SLI value has fresh data..."
Start-Sleep -Seconds 90

# ---------------------------------------------------------------------------
# 3. Inject the fault on the target service.
# ---------------------------------------------------------------------------
Write-Step "3 - Inject the fault (chaos) on '$Service'"
Invoke-RestMethod -Method Post "$backend/admin/chaos" -Body (@{ service = $Service; errorRate = $ErrorRate; extraLatencyMs = 0 } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
$injectedAt = Get-Date
$watchSinceUtc = $injectedAt.ToUniversalTime()
Log "Chaos injected (errorRate $ErrorRate). Watching for the SLI alert to fire..."

# ---------------------------------------------------------------------------
# 4. Watch Azure Monitor Alerts for the fired alert in the agent's scope.
# ---------------------------------------------------------------------------
Write-Step "4 - Watch for the alert (it should fire in ~2-3 min)"
$fired = $null
$deadline = (Get-Date).AddMinutes($WatchMinutes)
while ((Get-Date) -lt $deadline) {
  $aurl = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview"
  $j = az rest --method get --url $aurl -o json 2>$null | ConvertFrom-Json
  $fired = $j.value | Where-Object {
    $_.properties.essentials.targetResourceGroup -eq $SliResourceGroup -and
    $_.properties.essentials.alertRule -like "*$RuleGroupName*" -and
    $_.properties.essentials.monitorCondition -eq 'Fired' -and
    $_.properties.essentials.startDateTime -and
    ([datetime]$_.properties.essentials.startDateTime) -gt $watchSinceUtc
  } | Select-Object -First 1
  if ($fired) { break }
  Start-Sleep -Seconds 20
  Write-Host '.' -NoNewline
}
Write-Host ''

if (-not $fired) {
  Write-Warn "The alert did not fire within $WatchMinutes min. Check traffic is flowing and the SLI + its alert exist (../01-sli-demo)."
  Write-Info "Traffic job '$($job.Name)' is still running. Reset the fault with: ./sli-alert-scenario.ps1 -TeardownAlert"
  return
}
$e = $fired.properties.essentials
$elapsed = [int]((Get-Date) - $injectedAt).TotalSeconds
Write-Good "Alert FIRED (~${elapsed}s after the fault): $($fired.name)"
Write-Info "  severity : $($e.severity)   monitorService : $($e.monitorService)"
Write-Info "  targetRG : $($e.targetResourceGroup)  (in the agent's managed scope)"

# ---------------------------------------------------------------------------
# 5. Hand off to the agent.
# ---------------------------------------------------------------------------
Write-Step "5 - The SRE Agent engages"
Write-Info 'The agent ingests this Sev1 alert (incident source = Azure Monitor) and opens an'
Write-Info 'investigation. With the uploaded knowledge base it reads the topology + runbooks, finds the'
Write-Info 'chaos root cause, and (Autonomous + Owner) resets it, then verifies recovery. Watch Incidents:'
Write-Info "  https://sre.azure.com/#/agent/$sub/$AgentResourceGroup/$AgentName"
Write-Host ''
Write-Info 'If the agent is approval-only, approve the proposed fix; or apply it yourself:'
Write-Info "  ./src/remediation-runbooks/disable-chaos.ps1"
Write-Info 'Checkout availability recovers and the alert auto-resolves (~5m).'
Write-Host ''
Write-Info "When done: ./sli-alert-scenario.ps1 -TeardownAlert   (removes the alert, resets chaos, stops traffic)"
