// amwingest.bicep
// Deployed scoped to the Azure Monitor Workspace's auto-created managed resource group
// (MA_<amwName>_<region>_managed). It reads the metrics ingestion endpoint and the data
// collection rule immutable ID (needed to build the Prometheus remote-write URL), and grants
// the user-assigned managed identity Monitoring Metrics Publisher on that DCR so the proxy can
// remote-write metrics to the workspace.

@description('Azure Monitor Workspace name. The managed DCE and DCR share this name.')
param amwName string

@description('Principal ID of the user-assigned managed identity used by the remote-write proxy.')
param principalId string

var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' existing = {
  name: amwName
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: amwName
}

resource dcrPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, principalId, monitoringMetricsPublisher)
  scope: dcr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
  }
}

// Monitoring Reader on the destination workspace default DCR is required by the SLI
// engine (Service level indicators prerequisites) so it can read metric metadata when
// validating and evaluating SLIs.
resource dcrReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, principalId, monitoringReader)
  scope: dcr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
  }
}

output metricsIngestionEndpoint string = dce.properties.metricsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
