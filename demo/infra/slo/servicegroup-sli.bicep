// Declarative (Bicep) equivalent of deploy-slo.ps1 steps 2 and 5: the tenant-scoped
// Service Group and the three SLIs authored as extension resources on it.
//
// NOTES
//  * Service Groups are tenant-level, so this template deploys at tenant scope:
//      az deployment tenant create --location <region> --template-file servicegroup-sli.bicep --parameters ...
//    The deploying principal needs write access at the tenant root service group.
//  * SLIs (Microsoft.Monitor/slis) are a preview extension resource on the Service
//    Group. They reference Prometheus recording-rule metrics in the Azure Monitor
//    Workspace (deploy recording-rules.bicep into the workspace's resource group
//    first). The SLI query engine only sees dimensions on recording-rule metrics.
//  * Resource-group membership (Microsoft.Relationships/serviceGroupMember) is
//    resource-group scoped, so it is handled by deploy-slo.ps1, not here.
//
// For an end-to-end, self-validating run prefer deploy-slo.ps1. This file documents
// the same resources declaratively for review and policy/CI use.

targetScope = 'tenant'

@description('Service Group name (must be unique in the tenant).')
param serviceGroupName string

@description('Service Group display name.')
param serviceGroupDisplayName string = 'Checkout Service Group (SLI demo)'

@description('Tenant ID (parent root service group name).')
param tenantId string = tenant().tenantId

@description('Resource ID of the Azure Monitor Workspace holding the recording-rule metrics.')
param azureMonitorWorkspaceId string

@description('Resource ID of the user-assigned managed identity with Monitoring access to the workspace.')
param sliManagedIdentityId string

resource serviceGroup 'Microsoft.Management/serviceGroups@2024-02-01-preview' = {
  name: serviceGroupName
  properties: {
    displayName: serviceGroupDisplayName
    parent: {
      resourceId: '/providers/Microsoft.Management/serviceGroups/${tenantId}'
    }
  }
}

// Shared building blocks -----------------------------------------------------
var amwIdentity = {
  resourceId: azureMonitorWorkspaceId
  identity: sliManagedIdentityId
}

func requestSource(metric string, filters array, dimension string, amwId string, uamiId string) object => {
  signalSourceId: 'A'
  metricNamespace: 'customdefault'
  metricName: metric
  sourceAmwAccountManagedIdentity: uamiId
  sourceAmwAccountResourceId: amwId
  filters: filters
  spatialAggregation: {
    type: 'Sum'
    dimensions: [ dimension ]
  }
  temporalAggregation: {
    type: 'Average'
  }
}

// SLI 1: Checkout availability (request success ratio 2xx / all) -------------
resource checkoutAvailability 'Microsoft.Monitor/slis@2025-03-01-preview' = {
  scope: serviceGroup
  name: 'CheckoutAvailabilitySLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sliManagedIdentityId}': {}
    }
  }
  properties: {
    description: 'Checkout request success rate: HTTP 2xx responses divided by all checkout requests. Target 99.9%.'
    category: 'Availability'
    evaluationType: 'RequestBased'
    enableAlert: true
    destinationAmwAccounts: [ amwIdentity ]
    baselineProperties: {
      baseline: {
        value: json('99.9')
        evaluationPeriodDays: 7
        evaluationCalculationType: 'RollingDays'
      }
    }
    sliProperties: {
      goodSignals: {
        signalSources: [
          requestSource('sli:http_requests:rate5m', [
            { dimensionName: 'service', operator: 'eq', value: 'checkout' }
            { dimensionName: 'status_class', operator: 'eq', value: '2xx' }
          ], 'service', azureMonitorWorkspaceId, sliManagedIdentityId)
        ]
        signalFormula: 'A'
      }
      totalSignals: {
        signalSources: [
          requestSource('sli:http_requests:rate5m', [
            { dimensionName: 'service', operator: 'eq', value: 'checkout' }
          ], 'service', azureMonitorWorkspaceId, sliManagedIdentityId)
        ]
        signalFormula: 'A'
      }
    }
  }
}

// SLI 2: Login latency (P95 <= 300 ms window-based) --------------------------
resource loginLatency 'Microsoft.Monitor/slis@2025-03-01-preview' = {
  scope: serviceGroup
  name: 'LoginLatencySLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sliManagedIdentityId}': {}
    }
  }
  properties: {
    description: 'Login P95 latency under 300 ms. A window is good when P95 latency is at or below 0.3 seconds. Target 99% of windows.'
    category: 'Latency'
    evaluationType: 'WindowBased'
    enableAlert: true
    destinationAmwAccounts: [ amwIdentity ]
    baselineProperties: {
      baseline: {
        value: 99
        evaluationPeriodDays: 7
        evaluationCalculationType: 'RollingDays'
      }
    }
    sliProperties: {
      windowUptimeCriteria: {
        target: json('0.3')
        comparator: 'lte'
      }
      signals: {
        signalSources: [
          {
            signalSourceId: 'A'
            metricNamespace: 'customdefault'
            metricName: 'sli:http_request_latency_p95:5m'
            sourceAmwAccountManagedIdentity: sliManagedIdentityId
            sourceAmwAccountResourceId: azureMonitorWorkspaceId
            filters: [
              { dimensionName: 'service', operator: 'eq', value: 'login' }
            ]
            spatialAggregation: {
              type: 'Average'
              dimensions: [ 'service' ]
            }
            temporalAggregation: {
              type: 'Average'
              windowSizeMinutes: 5
            }
          }
        ]
        signalFormula: 'A'
      }
    }
  }
}

// SLI 3: Payment dependency availability (status ok / all) ------------------
resource paymentDependency 'Microsoft.Monitor/slis@2025-03-01-preview' = {
  scope: serviceGroup
  name: 'PaymentDependencySLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sliManagedIdentityId}': {}
    }
  }
  properties: {
    description: 'Payment dependency success rate: successful payment calls divided by all payment calls. Target 99.5%.'
    category: 'Availability'
    evaluationType: 'RequestBased'
    enableAlert: true
    destinationAmwAccounts: [ amwIdentity ]
    baselineProperties: {
      baseline: {
        value: json('99.5')
        evaluationPeriodDays: 7
        evaluationCalculationType: 'RollingDays'
      }
    }
    sliProperties: {
      goodSignals: {
        signalSources: [
          requestSource('sli:dependency_calls:rate5m', [
            { dimensionName: 'dependency', operator: 'eq', value: 'payment' }
            { dimensionName: 'status', operator: 'eq', value: 'ok' }
          ], 'dependency', azureMonitorWorkspaceId, sliManagedIdentityId)
        ]
        signalFormula: 'A'
      }
      totalSignals: {
        signalSources: [
          requestSource('sli:dependency_calls:rate5m', [
            { dimensionName: 'dependency', operator: 'eq', value: 'payment' }
          ], 'dependency', azureMonitorWorkspaceId, sliManagedIdentityId)
        ]
        signalFormula: 'A'
      }
    }
  }
}

output serviceGroupId string = serviceGroup.id
output sliIds array = [
  checkoutAvailability.id
  loginLatency.id
  paymentDependency.id
]
