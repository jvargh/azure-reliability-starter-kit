// Prometheus recording rules that pre-aggregate the demo metrics with the labels
// the SLI engine needs as dimensions. The SLI (Microsoft.Monitor/slis) query engine
// reads metrics from the Azure Monitor Workspace through the MDM metadata bridge, and
// that bridge only exposes dimensions for metrics that come from a recording rule
// (raw remote-written series have no registered dimensions). Each recording rule below
// emits a new metric whose `by (...)` labels become queryable SLI dimensions.
//
// Scope: resource group (same RG as the Azure Monitor Workspace).

@description('Azure region for the rule group.')
param location string = resourceGroup().location

@description('Resource ID of the Azure Monitor Workspace that stores the Prometheus metrics.')
param azureMonitorWorkspaceId string

@description('Name prefix used by the demo (matches the main deployment).')
param namePrefix string = 'slidemo'

@description('Evaluation interval for the recording rules.')
param interval string = 'PT1M'

resource sliRecordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: '${namePrefix}-sli-recording-rules'
  location: location
  properties: {
    description: 'Recording rules that expose SLI-ready dimensions for the Checkout/Login demo.'
    scopes: [
      azureMonitorWorkspaceId
    ]
    enabled: true
    interval: interval
    rules: [
      // Request rate (req/s) per service and status class. Feeds availability SLIs:
      // good = status_class="2xx", total = all status classes.
      {
        record: 'sli:http_requests:rate5m'
        expression: 'sum by (service, status_class) (rate(http_server_requests_total[5m]))'
      }
      // Dependency call rate (req/s) per dependency and status. Feeds the payment
      // dependency SLI: good = status="ok", total = all statuses.
      {
        record: 'sli:dependency_calls:rate5m'
        expression: 'sum by (dependency, status) (rate(dependency_calls_total[5m]))'
      }
      // P95 request latency (seconds) per service. Feeds the login latency SLI.
      {
        record: 'sli:http_request_latency_p95:5m'
        expression: 'histogram_quantile(0.95, sum by (service, le) (rate(http_server_request_duration_seconds_bucket[5m])))'
      }
      // Average request latency (seconds) per service. Alternative latency signal.
      {
        record: 'sli:http_request_latency_avg:5m'
        expression: 'sum by (service) (rate(http_server_request_duration_seconds_sum[5m])) / sum by (service) (rate(http_server_request_duration_seconds_count[5m]))'
      }
    ]
  }
}

output ruleGroupId string = sliRecordingRules.id
output ruleGroupName string = sliRecordingRules.name
