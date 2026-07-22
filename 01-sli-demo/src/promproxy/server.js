// server.js
// Prometheus remote-write auth proxy for Azure Monitor Workspace.
//
// The OpenTelemetry Collector's prometheusremotewrite exporter POSTs Snappy-compressed
// protobuf to this proxy. The proxy acquires an Entra token via the platform managed-identity
// endpoint (App Service / Container Apps IDENTITY_ENDPOINT, NOT IMDS), attaches it as a Bearer
// token, and forwards the request unchanged to the Azure Monitor Workspace remote-write URL.
//
// This replaces the Microsoft prom-remotewrite sidecar, which only authenticates via IMDS
// (169.254.169.254) and therefore cannot run on App Service or Container Apps.
//
// Required env:
//   AMW_WRITE_URL   Full AMW remote-write URL, e.g.
//                   https://<amw>.<region>.metrics.ingest.monitor.azure.com/dataCollectionRules/<dcrImmutableId>/streams/Microsoft-PrometheusMetrics/api/v1/write?api-version=2023-04-24
//   AZURE_CLIENT_ID Client ID of the user-assigned managed identity (omit to use system-assigned).

const express = require('express');
const { ManagedIdentityCredential, DefaultAzureCredential } = require('@azure/identity');

const AMW_WRITE_URL = process.env.AMW_WRITE_URL;
const SCOPE = 'https://monitor.azure.com/.default';

if (!AMW_WRITE_URL) {
  console.error('AMW_WRITE_URL is required');
  process.exit(1);
}

const credential = process.env.AZURE_CLIENT_ID
  ? new ManagedIdentityCredential(process.env.AZURE_CLIENT_ID)
  : new DefaultAzureCredential();

// Simple token cache, refresh ~5 min before expiry.
let cachedToken = null;
let cachedExp = 0;
async function getToken() {
  const now = Date.now();
  if (cachedToken && now < cachedExp - 5 * 60 * 1000) return cachedToken;
  const t = await credential.getToken(SCOPE);
  cachedToken = t.token;
  cachedExp = t.expiresOnTimestamp;
  return cachedToken;
}

const app = express();

// Read the raw request body ourselves. We must NOT use a body parser: the payload is
// Snappy-compressed Prometheus remote-write protobuf, and body-parser rejects the "snappy"
// Content-Encoding with HTTP 415. We forward the exact compressed bytes to the workspace.
function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

app.get('/healthz', (req, res) => res.json({ status: 'healthy' }));

app.post('/api/v1/write', async (req, res) => {
  try {
    const body = await readRawBody(req);
    const token = await getToken();
    const headers = {
      'Authorization': `Bearer ${token}`,
      'Content-Type': req.headers['content-type'] || 'application/x-protobuf',
      'Content-Encoding': req.headers['content-encoding'] || 'snappy',
      'X-Prometheus-Remote-Write-Version': req.headers['x-prometheus-remote-write-version'] || '0.1.0'
    };
    const upstream = await fetch(AMW_WRITE_URL, { method: 'POST', headers, body });
    const text = await upstream.text();
    if (!upstream.ok) {
      console.error(`remote-write failed ${upstream.status}: ${text.slice(0, 500)}`);
    }
    res.status(upstream.status).send(text);
  } catch (err) {
    console.error('proxy error', err);
    res.status(502).json({ error: String(err) });
  }
});

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`promproxy listening on ${port}, target=${AMW_WRITE_URL}`));
