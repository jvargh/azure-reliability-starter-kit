// main.bicep
// Provisions the entire SLI/SLO demo on App Service only (no Container Apps):
//   - Log Analytics, Application Insights, Azure Monitor Workspace
//   - User-assigned managed identity with the required Monitoring roles (AMW account + DCR)
//   - Frontend + Backend apps, the OpenTelemetry Collector (container web app), and the
//     managed-identity Prometheus remote-write proxy
// After this deploys, push the Node app code with infra-deploy.ps1 (or az webapp deploy).

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix for resource names.')
param namePrefix string = 'slidemo'

@description('App Service plan SKU (P1v3 recommended; B1 for lower cost).')
param planSku string = 'P1v3'

var suffix = uniqueString(resourceGroup().id)
var amwName = '${namePrefix}-amw-${suffix}'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    monitorAccountId: monitoring.outputs.monitorAccountId
  }
}

// Grant the identity Monitoring Metrics Publisher on the AMW's managed data collection rule and
// read the metrics ingestion endpoint + DCR immutable ID (deployed into the AMW managed RG).
// The managed RG and AMW names are deterministic, so they can be used as a module scope.
module amwIngest 'modules/amwingest.bicep' = {
  name: 'amwIngest'
  scope: resourceGroup('MA_${amwName}_${location}_managed')
  dependsOn: [
    monitoring
  ]
  params: {
    amwName: amwName
    principalId: identity.outputs.principalId
  }
}

var amwWriteUrl = '${amwIngest.outputs.metricsIngestionEndpoint}/dataCollectionRules/${amwIngest.outputs.dcrImmutableId}/streams/Microsoft-PrometheusMetrics/api/v1/write?api-version=2023-04-24'

module apps 'modules/appservice.bicep' = {
  name: 'appservice'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    planSku: planSku
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    identityResourceId: identity.outputs.identityId
    identityClientId: identity.outputs.clientId
    amwWriteUrl: amwWriteUrl
  }
}

output backendName string = apps.outputs.backendName
output frontendName string = apps.outputs.frontendName
output proxyName string = apps.outputs.proxyName
output collectorName string = apps.outputs.collectorName
output frontendUrl string = 'https://${apps.outputs.frontendDefaultHostname}'
output backendUrl string = 'https://${apps.outputs.backendDefaultHostname}'
output collectorUrl string = 'https://${apps.outputs.collectorDefaultHostname}'
output proxyUrl string = 'https://${apps.outputs.proxyDefaultHostname}'
output azureMonitorWorkspaceId string = monitoring.outputs.monitorAccountId
output azureMonitorWorkspaceName string = monitoring.outputs.monitorAccountName
output azureMonitorQueryEndpoint string = monitoring.outputs.metricsIngestionEndpoint
output amwRemoteWriteUrl string = amwWriteUrl
output sliManagedIdentityId string = identity.outputs.identityId
output sliManagedIdentityClientId string = identity.outputs.clientId

// Reuse this suffix when naming the Service Group so the name is unique and consistent
// with the deployed resources (Service Group names must be unique in the tenant).
output namingSuffix string = suffix
output suggestedServiceGroupName string = 'CheckoutSG-${suffix}'
