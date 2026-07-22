// appservice.bicep
// Linux App Service plan hosting the full App-Service-only telemetry pipeline:
//   - promproxy : Node app that attaches a managed-identity Entra token and forwards Prometheus
//                 remote-write requests to the Azure Monitor Workspace.
//   - collector : OpenTelemetry Collector (container image) that receives OTLP from the apps,
//                 sends traces to Application Insights and metrics to the proxy.
//   - backend   : the SLI demo API (/login, /checkout, payment dependency, chaos endpoint).
//   - frontend  : the SLI demo web app.
//
// Dependency order is expressed through property references:
//   proxy -> collector (AMW_PROXY_WRITE_URL) -> backend/frontend (OTEL_EXPORTER_OTLP_ENDPOINT).

param location string
param namePrefix string
param suffix string
param appInsightsConnectionString string

@description('Resource ID of the user-assigned managed identity (used by the proxy).')
param identityResourceId string

@description('Client ID of the user-assigned managed identity (used by the proxy to acquire tokens).')
param identityClientId string

@description('Full Azure Monitor Workspace Prometheus remote-write URL.')
param amwWriteUrl string

@description('App Service plan SKU.')
param planSku string = 'P1v3'

var backendName = '${namePrefix}-be-${suffix}'
var frontendName = '${namePrefix}-fe-${suffix}'
var proxyName = '${namePrefix}-promproxy-${suffix}'
var collectorName = '${namePrefix}-otelcolapp-${suffix}'

// Full collector config embedded at build time. It references ${env:AMW_PROXY_WRITE_URL} and
// ${env:APPLICATIONINSIGHTS_CONNECTION_STRING}, which the collector resolves from its app settings.
var collectorConfig = loadTextContent('../collector/collector-config.yaml')

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${backendName}-plan'
  location: location
  sku: {
    name: planSku
    tier: planSku == 'P1v3' ? 'PremiumV3' : 'Basic'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

// Remote-write auth proxy (Node).
resource proxy 'Microsoft.Web/sites@2023-12-01' = {
  name: proxyName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      appCommandLine: 'node server.js'
      healthCheckPath: '/healthz'
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'WEBSITES_PORT', value: '8080' }
        { name: 'AZURE_CLIENT_ID', value: identityClientId }
        { name: 'AMW_WRITE_URL', value: amwWriteUrl }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
      ]
    }
  }
}

// OpenTelemetry Collector (container). Config is provided via the COLLECTOR_CONFIG app setting
// and read with --config=env:COLLECTOR_CONFIG.
resource collector 'Microsoft.Web/sites@2023-12-01' = {
  name: collectorName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|otel/opentelemetry-collector-contrib:0.111.0'
      appCommandLine: '--config=env:COLLECTOR_CONFIG'
      appSettings: [
        { name: 'WEBSITES_PORT', value: '4318' }
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'WEBSITES_CONTAINER_START_TIME_LIMIT', value: '600' }
        { name: 'COLLECTOR_CONFIG', value: collectorConfig }
        { name: 'AMW_PROXY_WRITE_URL', value: 'https://${proxy.properties.defaultHostName}/api/v1/write' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
      ]
    }
  }
}

resource backend 'Microsoft.Web/sites@2023-12-01' = {
  name: backendName
  location: location
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      appCommandLine: 'node server.js'
      healthCheckPath: '/healthz'
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'WEBSITES_PORT', value: '8080' }
        { name: 'OTEL_SERVICE_NAME', value: 'sli-demo-backend' }
        { name: 'OTEL_EXPORTER_OTLP_ENDPOINT', value: 'https://${collector.properties.defaultHostName}' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
      ]
    }
  }
}

resource frontend 'Microsoft.Web/sites@2023-12-01' = {
  name: frontendName
  location: location
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      appCommandLine: 'node server.js'
      healthCheckPath: '/healthz'
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'WEBSITES_PORT', value: '8080' }
        { name: 'OTEL_SERVICE_NAME', value: 'sli-demo-frontend' }
        { name: 'OTEL_EXPORTER_OTLP_ENDPOINT', value: 'https://${collector.properties.defaultHostName}' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'BACKEND_URL', value: 'https://${backend.properties.defaultHostName}' }
      ]
    }
  }
}

output backendName string = backendName
output frontendName string = frontendName
output proxyName string = proxyName
output collectorName string = collectorName
output backendDefaultHostname string = backend.properties.defaultHostName
output frontendDefaultHostname string = frontend.properties.defaultHostName
output proxyDefaultHostname string = proxy.properties.defaultHostName
output collectorDefaultHostname string = collector.properties.defaultHostName
