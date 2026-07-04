# build-slo-workbook.ps1
# Generates slo-dashboard.workbook (an Azure Monitor Workbook) that renders the
# Checkout Service Group SLIs from the recording rules in the Azure Monitor Workspace.
# The workbook uses the Prometheus data source (queryType 16) so the panels populate
# from sli:* recording rules - independent of the preview SLI writeback.
#
# Run:  pwsh -File build-slo-workbook.ps1
# Output: slo-dashboard.workbook (consumed by slo-workbook.bicep via loadTextContent)

$amwId = '/subscriptions/463a82d4-1896-4332-aeeb-618ee5a5aa93/resourceGroups/rg-sli-demo/providers/Microsoft.Monitor/accounts/slidemo-amw-ioarvugvrpkmc'
$outFile = Join-Path $PSScriptRoot 'slo-dashboard.workbook'

function New-Guid2 { [guid]::NewGuid().ToString() }

# Builds a Prometheus query item (queryType 16). $type = 'query' (instant) or 'query_range' (trend).
function New-PromItem {
  param([string]$Title, [string]$PromQL, [string]$Viz = 'timechart', [string]$Type = 'query_range', [int]$Size = 0, [string]$Unit = '')
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
    # group:* groups by the series-label column; ySettings matches the canonical Prometheus Explorer workbook.
    $content.chartSettings = [ordered]@{
      group            = '*'
      createOtherGroup = 50
      showLegend       = $true
      ySettings        = @{ numberFormatSettings = @{ unit = 0; options = @{ style = 'decimal'; useGrouping = $true; maximumFractionDigits = 2 } } }
    }
  }
  [ordered]@{ type = 3; content = $content; name = ($Title -replace '[^a-zA-Z0-9]', '').ToLower() }
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
        value        = @{ durationMs = 3600000 }
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
    json  = "## Checkout Service Group - SLO Dashboard`r`n`r`nSLI availability, latency and error-budget burn rate for the **Login + Checkout** workload, computed from the ``sli:*`` recording rules in the Azure Monitor Workspace. Targets: Checkout 99.9% | Login latency P95 <= 300 ms (99%) | Payment dependency 99.5%."
    style = 'info'
  }
  name    = 'header'
}

# --- SLI panels ---
$checkoutAvail = 'clamp_max(100 * sum(sli:http_requests:rate5m{service="checkout",status_class="2xx"}) / sum(sli:http_requests:rate5m{service="checkout"}), 100)'
$loginAvail    = 'clamp_max(100 * sum(sli:http_requests:rate5m{service="login",status_class="2xx"}) / sum(sli:http_requests:rate5m{service="login"}), 100)'
$paymentAvail  = 'clamp_max(100 * sum(sli:dependency_calls:rate5m{dependency="payment",status="ok"}) / sum(sli:dependency_calls:rate5m{dependency="payment"}), 100)'
$loginP95      = 'sli:http_request_latency_p95:5m{service="login"}'
$checkoutBurn  = '(sum(sli:http_requests:rate5m{service="checkout",status_class="5xx"}) / sum(sli:http_requests:rate5m{service="checkout"})) / 0.001'

# Trend (range) variants: label_replace injects a constant `series` label so the timechart has a
# dimension column to group on. Without a label, sum()-collapsed series produce no group column and
# the workbook reports "Could not find appropriate columns for Time chart".
$checkoutAvailTrend = "label_replace($checkoutAvail, `"series`", `"checkout_availability`", `"`", `"`")"
$paymentAvailTrend  = "label_replace($paymentAvail, `"series`", `"payment_dependency`", `"`", `"`")"
$loginP95Trend      = "label_replace($loginP95, `"series`", `"login_p95`", `"`", `"`")"
$checkoutBurnTrend  = "label_replace($checkoutBurn, `"series`", `"checkout_burn_rate`", `"`", `"`")"

$items = @(
  $header,
  $timeParam,
  # Current-value panels (instant queries, grid visualization renders the latest value)
  (New-PromItem -Title 'Checkout Availability SLI % (target 99.9)' -PromQL $checkoutAvail -Viz 'table' -Type 'query' -Size 4),
  (New-PromItem -Title 'Login Availability SLI % (target 99)'      -PromQL $loginAvail    -Viz 'table' -Type 'query' -Size 4),
  (New-PromItem -Title 'Payment Dependency SLI % (target 99.5)'    -PromQL $paymentAvail  -Viz 'table' -Type 'query' -Size 4),
  (New-PromItem -Title 'Checkout Error-Budget Burn Rate (x of 0.1%)' -PromQL $checkoutBurn -Viz 'table' -Type 'query' -Size 4),
  (New-PromItem -Title 'Login P95 Latency seconds (threshold 0.3)' -PromQL $loginP95      -Viz 'table' -Type 'query' -Size 4),
  # Trend charts (range queries; label_replace gives each chart a named series column)
  (New-PromItem -Title 'Checkout Availability SLI % - trend' -PromQL $checkoutAvailTrend -Viz 'timechart'),
  (New-PromItem -Title 'Payment Dependency SLI % - trend'    -PromQL $paymentAvailTrend  -Viz 'timechart'),
  (New-PromItem -Title 'Login P95 Latency (s) - trend vs 0.3 threshold' -PromQL $loginP95Trend -Viz 'timechart'),
  (New-PromItem -Title 'Checkout Error-Budget Burn Rate (x) - trend' -PromQL $checkoutBurnTrend -Viz 'timechart')
)

$workbook = [ordered]@{
  version  = 'Notebook/1.0'
  items    = $items
  '$schema' = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

$json = $workbook | ConvertTo-Json -Depth 40
Set-Content -Path $outFile -Value $json -Encoding utf8
Write-Host "Wrote $outFile ($($json.Length) chars, $($items.Count) items)"
