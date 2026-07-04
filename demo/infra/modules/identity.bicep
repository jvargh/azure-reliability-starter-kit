// identity.bicep
// User-assigned managed identity used by the SLI engine to read source metrics and publish
// evaluated SLI results to the Azure Monitor Workspace. Grants the roles from the SLI docs.

param location string
param namePrefix string
param suffix string

@description('Resource ID of the Azure Monitor Workspace (Microsoft.Monitor/accounts).')
param monitorAccountId string

// Built-in role definition IDs
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
// Monitoring Data Reader: required for the SLI streaming-rule engine to query the
// workspace Prometheus (data-plane) endpoint and read the source signals. Without
// this the engine reads nothing and the SLI panels show "query returned no results".
var monitoringDataReader = 'b0d8363b-8ddd-447d-831f-62ca05bff136'

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-id-${suffix}'
  location: location
}

resource monitorAccount 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: last(split(monitorAccountId, '/'))
}

// Monitoring Metrics Publisher on the destination workspace (publish evaluated results).
resource publisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitorAccountId, uami.id, monitoringMetricsPublisher)
  scope: monitorAccount
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
  }
}

// Monitoring Reader on the source workspace (read source metrics).
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitorAccountId, uami.id, monitoringReader)
  scope: monitorAccount
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
  }
}

// Monitoring Data Reader on the source workspace: lets the SLI streaming-rule engine
// query the workspace Prometheus (data-plane) endpoint for the source signals. This is
// the role that actually makes the SLI panels populate (Monitoring Reader alone is not
// enough; it only grants control-plane reads).
resource dataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitorAccountId, uami.id, monitoringDataReader)
  scope: monitorAccount
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringDataReader)
  }
}

output identityId string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
