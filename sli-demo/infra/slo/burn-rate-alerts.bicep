// Error-budget burn-rate alerting implemented as managed Prometheus rules.
//
// This is the reliable alternative to the preview Microsoft.Monitor/slis resource:
// it computes the SLO, error budget, and multi-window burn rate directly from the
// raw counters with PromQL, entirely inside the Azure Monitor Workspace. There is no
// dependency on the SLI engine's metric-dimension metadata bridge, so it is not
// affected by the dimension-registration flakiness that blocks SLI creation.
//
// Method: Google SRE multi-window, multi-burn-rate alerting.
//   - Fast burn (page):  14.4x burn over 1h, confirmed by a 5m window. Burns ~2% of
//                        the 30-day budget in 1 hour.
//   - Slow burn (ticket): 6x burn over 6h, confirmed by a 30m window. Burns ~10% of
//                        the budget in ~3 days.
// Burn-rate threshold = factor * (1 - SLO). An alert fires only when BOTH the long and
// short windows exceed the threshold, which suppresses flapping.
//
// Scope: resource group (same RG as the Azure Monitor Workspace).

@description('Azure region for the rule group.')
param location string = resourceGroup().location

@description('Resource ID of the Azure Monitor Workspace that stores the Prometheus metrics.')
param azureMonitorWorkspaceId string

@description('Name prefix used by the demo (matches the main deployment).')
param namePrefix string = 'slidemo'

@description('Optional action group resource ID to notify when an alert fires. Leave empty to just surface alerts in Azure Monitor.')
param actionGroupId string = ''

@description('Evaluation interval for the rules.')
param interval string = 'PT1M'

// SLO targets -> error budgets (1 - SLO), then burn-rate thresholds = factor * budget.
// Checkout SLO 99.9% (budget 0.001): fast 14.4x = 0.0144, slow 6x = 0.006.
// Payment  SLO 99.5% (budget 0.005): fast 14.4x = 0.072,  slow 6x = 0.030.
var checkoutFast = '0.0144'
var checkoutSlow = '0.006'
var paymentFast = '0.072'
var paymentSlow = '0.03'

var alertActions = empty(actionGroupId) ? [] : [
  {
    actionGroupId: actionGroupId
  }
]

resource burnRateRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: '${namePrefix}-slo-burn-rate-alerts'
  location: location
  properties: {
    description: 'SLO error-budget burn-rate recording rules and multi-window alerts for the Checkout demo.'
    scopes: [
      azureMonitorWorkspaceId
    ]
    enabled: true
    interval: interval
    rules: [
      // ---- Checkout availability error ratios (5xx / all) over 4 windows ----
      {
        record: 'slo:checkout_availability:error_ratio5m'
        expression: 'sum(rate(http_server_requests_total{service="checkout",status_class="5xx"}[5m])) / sum(rate(http_server_requests_total{service="checkout"}[5m]))'
      }
      {
        record: 'slo:checkout_availability:error_ratio30m'
        expression: 'sum(rate(http_server_requests_total{service="checkout",status_class="5xx"}[30m])) / sum(rate(http_server_requests_total{service="checkout"}[30m]))'
      }
      {
        record: 'slo:checkout_availability:error_ratio1h'
        expression: 'sum(rate(http_server_requests_total{service="checkout",status_class="5xx"}[1h])) / sum(rate(http_server_requests_total{service="checkout"}[1h]))'
      }
      {
        record: 'slo:checkout_availability:error_ratio6h'
        expression: 'sum(rate(http_server_requests_total{service="checkout",status_class="5xx"}[6h])) / sum(rate(http_server_requests_total{service="checkout"}[6h]))'
      }
      // ---- Payment dependency error ratios (status="error" / all) over 4 windows ----
      {
        record: 'slo:payment_dependency:error_ratio5m'
        expression: 'sum(rate(dependency_calls_total{dependency="payment",status="error"}[5m])) / sum(rate(dependency_calls_total{dependency="payment"}[5m]))'
      }
      {
        record: 'slo:payment_dependency:error_ratio30m'
        expression: 'sum(rate(dependency_calls_total{dependency="payment",status="error"}[30m])) / sum(rate(dependency_calls_total{dependency="payment"}[30m]))'
      }
      {
        record: 'slo:payment_dependency:error_ratio1h'
        expression: 'sum(rate(dependency_calls_total{dependency="payment",status="error"}[1h])) / sum(rate(dependency_calls_total{dependency="payment"}[1h]))'
      }
      {
        record: 'slo:payment_dependency:error_ratio6h'
        expression: 'sum(rate(dependency_calls_total{dependency="payment",status="error"}[6h])) / sum(rate(dependency_calls_total{dependency="payment"}[6h]))'
      }

      // ---- Checkout availability burn-rate alerts (SLO 99.9%) ----
      {
        alert: 'CheckoutAvailabilityFastBurn'
        expression: 'slo:checkout_availability:error_ratio1h > ${checkoutFast} and slo:checkout_availability:error_ratio5m > ${checkoutFast}'
        for: 'PT2M'
        severity: 2
        labels: {
          slo: 'checkout-availability'
          burn: 'fast'
        }
        annotations: {
          summary: 'Checkout availability fast burn: consuming the error budget ~14.4x too fast.'
          description: 'The checkout 5xx error ratio over 1h and 5m both exceed 14.4 x (1 - 99.9%). At this rate ~2% of the 30-day budget is consumed per hour.'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT10M'
        }
        actions: alertActions
      }
      {
        alert: 'CheckoutAvailabilitySlowBurn'
        expression: 'slo:checkout_availability:error_ratio6h > ${checkoutSlow} and slo:checkout_availability:error_ratio30m > ${checkoutSlow}'
        for: 'PT15M'
        severity: 3
        labels: {
          slo: 'checkout-availability'
          burn: 'slow'
        }
        annotations: {
          summary: 'Checkout availability slow burn: sustained error-budget consumption.'
          description: 'The checkout 5xx error ratio over 6h and 30m both exceed 6 x (1 - 99.9%). Sustained degradation that will breach the SLO if it continues.'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT30M'
        }
        actions: alertActions
      }

      // ---- Payment dependency burn-rate alerts (SLO 99.5%) ----
      {
        alert: 'PaymentDependencyFastBurn'
        expression: 'slo:payment_dependency:error_ratio1h > ${paymentFast} and slo:payment_dependency:error_ratio5m > ${paymentFast}'
        for: 'PT2M'
        severity: 2
        labels: {
          slo: 'payment-dependency'
          burn: 'fast'
        }
        annotations: {
          summary: 'Payment dependency fast burn: consuming the error budget ~14.4x too fast.'
          description: 'The payment dependency error ratio over 1h and 5m both exceed 14.4 x (1 - 99.5%).'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT10M'
        }
        actions: alertActions
      }
      {
        alert: 'PaymentDependencySlowBurn'
        expression: 'slo:payment_dependency:error_ratio6h > ${paymentSlow} and slo:payment_dependency:error_ratio30m > ${paymentSlow}'
        for: 'PT15M'
        severity: 3
        labels: {
          slo: 'payment-dependency'
          burn: 'slow'
        }
        annotations: {
          summary: 'Payment dependency slow burn: sustained error-budget consumption.'
          description: 'The payment dependency error ratio over 6h and 30m both exceed 6 x (1 - 99.5%).'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT30M'
        }
        actions: alertActions
      }
    ]
  }
}

output ruleGroupId string = burnRateRules.id
output ruleGroupName string = burnRateRules.name
