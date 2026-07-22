// telemetry.js (frontend) - identical OTel setup, different service name.
// Service name is taken from the OTEL_SERVICE_NAME environment variable.
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');

const collector = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

let sdk;
try {
  sdk = new NodeSDK({
    traceExporter: new OTLPTraceExporter({ url: `${collector}/v1/traces` }),
    metricReader: new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: `${collector}/v1/metrics` }),
      exportIntervalMillis: 15000
    }),
    instrumentations: [getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false }
    })]
  });
  sdk.start();
  process.on('SIGTERM', () => { sdk.shutdown().finally(() => process.exit(0)); });
} catch (err) {
  console.error('OpenTelemetry init failed, continuing without telemetry:', err);
}
module.exports = sdk;
