// telemetry.js
// Initializes OpenTelemetry. The app speaks OTLP to the OpenTelemetry Collector,
// which fans out traces to Application Insights and metrics to the Azure Monitor Workspace.
// Must be required before any other module so HTTP/Express auto-instrumentation hooks in.
// Service name is taken from the OTEL_SERVICE_NAME environment variable.

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { PeriodicExportingMetricReader, ExplicitBucketHistogramAggregation, View } = require('@opentelemetry/sdk-metrics');

// Collector OTLP endpoint, for example https://<collector-app>.azurecontainerapps.io
const collector = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

let sdk;
try {
  sdk = new NodeSDK({
    traceExporter: new OTLPTraceExporter({ url: `${collector}/v1/traces` }),
    metricReader: new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: `${collector}/v1/metrics` }),
      exportIntervalMillis: 15000
    }),
    // Histogram buckets in seconds, with a boundary at 0.3s so the 300ms SLI is meaningful.
    views: [
      new View({
        instrumentName: 'http_server_request_duration_seconds',
        aggregation: new ExplicitBucketHistogramAggregation([0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5])
      })
    ],
    instrumentations: [getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false }
    })]
  });
  sdk.start();
  process.on('SIGTERM', () => {
    sdk.shutdown().finally(() => process.exit(0));
  });
} catch (err) {
  // Never let telemetry setup take the app down.
  console.error('OpenTelemetry init failed, continuing without telemetry:', err);
}

module.exports = sdk;
