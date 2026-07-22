// monitoring.bicep
// Log Analytics workspace, workspace-based Application Insights, and an Azure Monitor Workspace
// (the SLI source and destination metric store).

param location string
param namePrefix string
param suffix string

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// Azure Monitor Workspace: stores the Prometheus metrics that SLIs evaluate,
// and the evaluated SLI results.
resource monitorAccount 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: '${namePrefix}-amw-${suffix}'
  location: location
}

output lawId string = law.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output monitorAccountId string = monitorAccount.id
output monitorAccountName string = monitorAccount.name
output metricsIngestionEndpoint string = monitorAccount.properties.metrics.prometheusQueryEndpoint
