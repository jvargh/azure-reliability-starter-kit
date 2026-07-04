# build-sli-detail-workbook.ps1
# Generates sli-detail-dashboard.workbook - an Azure Monitor Workbook that reproduces the
# native "SLI performance" layout (Metric, Error Budget Remaining, Burn Rate) for EACH SLI,
# computed from the sli:* recording rules in the Azure Monitor Workspace via the Prometheus
# data source (queryType 16). Populates independently of the preview SLI writeback.
#
# Run:  pwsh -File build-sli-detail-workbook.ps1
# Output: sli-detail-dashboard.workbook (consumed by sli-detail-workbook.bicep via loadTextContent)

$amwId = '/subscriptions/463a82d4-1896-4332-aeeb-618ee5a5aa93/resourceGroups/rg-sli-demo/providers/Microsoft.Monitor/accounts/slidemo-amw-ioarvugvrpkmc'
$outFile = Join-Path $PSScriptRoot 'sli-detail-dashboard.workbook'

function New-Guid2 { [guid]::NewGuid().ToString() }

# Builds a Prometheus query item (queryType 16). $Type = 'query' (instant) or 'query_range' (trend).
# $Width sets the item customWidth so the 3 displays sit side by side per SLI.
function New-PromItem {
  param([string]$Title, [string]$PromQL, [string]$Viz = 'timechart', [string]$Type = 'query_range', [int]$Size = 0, [string]$Width = '33')
  $inner = @{ version = 'PrometheusQueryProvider/1.0'; queryText = $PromQL; type = $Type } | ConvertTo-Json -Compress
  $content = [ordered]@{
    version                  = 'KqlItem/1.0'
    query                    = $inner
    size                     = $Size
    aggregation              = 3
    showAnnotations          = $true
    title                    = $Title
    timeContextFromParameter = 'timerange'
    queryType                = 16
    resourceType             = 'microsoft.monitor/accounts'
    crossComponentResources  = @($amwId)
    visualization            = $Viz
  }
  if ($Viz -eq 'timechart') {
    $content.chartSettings = [ordered]@{
      group            = '*'
      createOtherGroup = 50
      showLegend       = $true
      ySettings        = @{ numberFormatSettings = @{ unit = 0; options = @{ style = 'decimal'; useGrouping = $true; maximumFractionDigits = 2 } } }
    }
  }
  [ordered]@{ type = 3; content = $content; customWidth = $Width; name = ($Title -replace '[^a-zA-Z0-9]', '').ToLower() }
}

# Builds the per-SLI block: a header + 3 trend charts (Metric, Error Budget Remaining, Burn Rate).
# All three are computed from the raw *_total counters via increase() so they survive traffic gaps:
#   - Metric and Burn Rate use a rolling 1h window (smoothed availability, holds steady across gaps,
#     never collapses to 0/0 when traffic momentarily pauses).
#   - Error Budget Remaining is CUMULATIVE over the 7d SLO window (only declines, never refills).
# $Eb is the error budget fraction (1 - target).
function New-SliBlock {
  param([string]$Name, [string]$GoodCtr, [string]$TotalCtr, [double]$Eb, [double]$TargetPct)

  # Rolling 12h availability for Metric + Burn. A window this wide always spans short traffic gaps
  # (the generator pausing for a few hours), so the line holds steady instead of collapsing to 0/0.
  $mw = '12h'
  $gWin = "sum(increase(${GoodCtr}[$mw]))"
  $tWin = "sum(increase(${TotalCtr}[$mw]))"
  # Metric: rolling SLI good-ratio %.
  $metric = "clamp_max(100 * $gWin / $tWin, 100)"
  # Burn Rate: multiple of the error budget being consumed over the rolling window (>1 = too fast).
  $burn = "((($tWin - $gWin) / $tWin) / $Eb)"

  # Error Budget Remaining %: CUMULATIVE over the SLO compliance window ($window). consumed = bad
  # events / (budget * total events) accumulated since the window start. As errors accrue the line
  # only goes down (or stays flat); floored at 0 when the budget is exhausted, so it never refills.
  $window = '7d'
  $goodInc = "sum(increase(${GoodCtr}[$window]))"
  $totalInc = "sum(increase(${TotalCtr}[$window]))"
  $consumed = "(($totalInc - $goodInc) / ($Eb * $totalInc))"
  $budget = "clamp_min(clamp_max(100 * (1 - $consumed), 100), 0)"

  $slug = ($Name -replace '[^a-zA-Z0-9]', '_').ToLower()
  # Reference lines so the breach is self-evident: the SLO target on the Metric chart and the
  # 1x error-budget line on the Burn Rate chart (anything above 1x is burning budget).
  $targetLine = "label_replace(vector($TargetPct), `"sli`", `"target_${TargetPct}pct`", `"`", `"`")"
  $burnLimit = "label_replace(vector(1), `"sli`", `"budget_limit_1x`", `"`", `"`")"
  $metricQ = "label_replace($metric, `"sli`", `"${slug}`", `"`", `"`") or $targetLine"
  $budgetQ = "label_replace($budget, `"sli`", `"${slug}`", `"`", `"`")"
  $burnQ = "label_replace($burn, `"sli`", `"${slug}`", `"`", `"`") or $burnLimit"

  $ebPct = [math]::Round($Eb * 100, 2)
  $header = [ordered]@{
    type    = 1
    content = [ordered]@{
      json  = "### $Name`r`n**Target $TargetPct%**  |  Error budget $ebPct%  |  Metric = rolling 12h SLI % (with the $TargetPct% target line - below it = breach), Error Budget Remaining = cumulative budget left over the 7d SLO window (only declines), Burn Rate = x of the error budget consumed (with the 1x line - above it = burning budget)."
      style = 'info'
    }
    name    = "hdr_$slug"
  }

  @(
    $header,
    (New-PromItem -Title "$Name - Metric (SLI %)" -PromQL $metricQ),
    (New-PromItem -Title "$Name - Error Budget Remaining (%)" -PromQL $budgetQ),
    (New-PromItem -Title "$Name - Burn Rate (x budget)" -PromQL $burnQ)
  )
}

$timeParam = [ordered]@{
  type    = 9
  content = [ordered]@{
    version      = 'KqlParameterItem/1.0'
    parameters   = @(
      [ordered]@{
        id           = (New-Guid2)
        version      = 'KqlParameterItem/1.0'
        name         = 'timerange'
        label        = 'Time Range'
        type         = 4
        isRequired   = $true
        value        = @{ durationMs = 14400000 }
        typeSettings = @{ selectableValues = @(
            @{ durationMs = 300000 }, @{ durationMs = 1800000 }, @{ durationMs = 3600000 },
            @{ durationMs = 14400000 }, @{ durationMs = 43200000 }, @{ durationMs = 86400000 },
            @{ durationMs = 604800000 }, @{ durationMs = 2592000000 }
          ); allowCustom = $true
        }
      }
    )
    style        = 'pills'
    queryType    = 0
    resourceType = 'microsoft.monitor/accounts'
  }
  name    = 'time-range'
}

$header = [ordered]@{
  type    = 1
  content = [ordered]@{
    json  = "## CheckoutSG - SLI Diagnostics`r`n`r`nTop two rows are the diagnostic signal: **Source data health** (is the source emitting?) and **SLI engine output** (has the engine published ``<SLI>:Value/Good/Total`` to namespace ``CheckoutSG-ioarvugvrpkmc``?). Below: per-SLI **Metric / Error Budget Remaining / Burn Rate** computed from the ``sli:*`` recording rules."
    style = 'info'
  }
  name    = 'header'
}

# --- Source data health sentinel (HONEST: no carry-forward, gaps show as 0) ---
# Raw 5m rate per source, mapped to 1 (emitting) or 0 (gap) with > bool 0 or vector(0).
# Unlike the SLI panels below (which use increase() over 12h/7d to stay smooth), this row
# never masks gaps - any drop to 0 is a window where the SLI engine publishes NoContent.
$sourceHealthQuery = @'
label_replace((sum(rate(http_server_requests_total{service="checkout"}[5m])) > bool 0) or vector(0), "source", "checkout", "", "") or label_replace((sum(rate(http_server_requests_total{service="login"}[5m])) > bool 0) or vector(0), "source", "login", "", "") or label_replace((sum(rate(dependency_calls_total{dependency="payment"}[5m])) > bool 0) or vector(0), "source", "payment", "", "")
'@

$sourceHealthHeader = [ordered]@{
  type    = 1
  content = [ordered]@{
    json  = "## Source data health (un-masked)`r`n`r`n**1 = source emitting, 0 = gap.** Raw 5m rate with no carry-forward, so any drop to 0 marks a window where the ``sli:*`` source has no data and the SLI engine publishes ``NoContent`` (the native SLI panel goes blank). The SLI charts below deliberately use wide ``increase()`` windows to stay smooth; this row does not, so use it to judge whether the source is actually continuous."
    style = 'warning'
  }
  name    = 'source-health-header'
}

# --- SLI engine output: the destination metrics the engine publishes ---
# The engine writes <SLI>:Value/Good/Total to the destination AMW. In Prometheus these surface
# as fully-qualified names: ns::<servicegroup>/m::<sli>:value. This panel plots the published
# :value for each SLI; lines here = the engine is publishing and the native panels populate.
$engineOutputQuery = @'
label_replace({__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:value"}, "sli", "checkout_availability", "", "") or label_replace({__name__="ns::checkoutsg-ioarvugvrpkmc/m::loginlatencysli:value"}, "sli", "login_latency", "", "") or label_replace({__name__="ns::checkoutsg-ioarvugvrpkmc/m::paymentdependencysli:value"}, "sli", "payment_dependency", "", "")
'@

$engineOutputHeader = [ordered]@{
  type    = 1
  content = [ordered]@{
    json  = "## SLI engine output - published values`r`n`r`nThese are the engine's **destination metrics** that the portal ""Manage SLIs"" status / error-budget columns read - the published SLI ``:value`` per SLI (surfaced in Prometheus as ``ns::checkoutsg-ioarvugvrpkmc/m::<sli>:value``). Lines here mean the engine is publishing end-to-end and the native panels are populated. Empty = nothing published."
    style = 'success'
  }
  name    = 'engine-output-header'
}

# --- SLI selectors (raw *_total counters; increase() makes every panel gap-resistant) ---
$checkoutGoodCtr  = 'http_server_requests_total{service="checkout",status_class="2xx"}'
$checkoutTotalCtr = 'http_server_requests_total{service="checkout"}'
$loginGoodCtr     = 'http_server_requests_total{service="login",status_class="2xx"}'
$loginTotalCtr    = 'http_server_requests_total{service="login"}'
$paymentGoodCtr   = 'dependency_calls_total{dependency="payment",status="ok"}'
$paymentTotalCtr  = 'dependency_calls_total{dependency="payment"}'

$items = @($header, $timeParam, $sourceHealthHeader,
  (New-PromItem -Title 'Source data present (1=emitting, 0=gap)' -PromQL $sourceHealthQuery -Width '100'),
  $engineOutputHeader,
  (New-PromItem -Title 'SLI engine output - published <sli>:value (the portal reads these)' -PromQL $engineOutputQuery -Width '100'))
$items += (New-SliBlock -Name 'Checkout Availability' -GoodCtr $checkoutGoodCtr -TotalCtr $checkoutTotalCtr -Eb 0.001 -TargetPct 99.9)
$items += (New-SliBlock -Name 'Login Availability'    -GoodCtr $loginGoodCtr    -TotalCtr $loginTotalCtr    -Eb 0.001 -TargetPct 99.9)
$items += (New-SliBlock -Name 'Payment Dependency'    -GoodCtr $paymentGoodCtr  -TotalCtr $paymentTotalCtr  -Eb 0.005 -TargetPct 99.5)

$workbook = [ordered]@{
  version   = 'Notebook/1.0'
  items     = $items
  '$schema' = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

$json = $workbook | ConvertTo-Json -Depth 40
Set-Content -Path $outFile -Value $json -Encoding utf8
Write-Host "Wrote $outFile ($($json.Length) chars, $($items.Count) items)"
