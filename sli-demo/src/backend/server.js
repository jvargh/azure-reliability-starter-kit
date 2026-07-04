// server.js
// Backend API for the SLI/SLO demo. Exposes /login, /checkout, calls a simulated
// payment dependency, and emits the custom OpenTelemetry metrics the SLIs read.
// An /admin/chaos endpoint tunes failure rate and latency to drive error-budget burn.

require('./telemetry'); // must be first

const express = require('express');
const { metrics } = require('@opentelemetry/api');

const app = express();
app.use(express.json());

const meter = metrics.getMeter('sli-demo');

// SLI source signals
const requestsTotal = meter.createCounter('http_server_requests_total', {
  description: 'Count of HTTP server requests by service, route and status class'
});
const requestDuration = meter.createHistogram('http_server_request_duration_seconds', {
  description: 'HTTP server request duration in seconds',
  unit: 's'
});
const dependencyCalls = meter.createCounter('dependency_calls_total', {
  description: 'Count of downstream dependency calls by dependency and status'
});

// Chaos knobs, tuned live via /admin/chaos
const chaos = {
  login: { errorRate: 0, extraLatencyMs: 0 },
  checkout: { errorRate: 0, extraLatencyMs: 0 }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const statusClass = (code) => `${Math.floor(code / 100)}xx`;

// Wraps a handler to record duration + request count metrics with service/route/status labels.
function instrument(service, route, handler) {
  return async (req, res) => {
    const start = process.hrtime.bigint();
    let code = 200;
    try {
      code = await handler(req, res);
    } catch (err) {
      code = 500;
    }
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    const labels = { service, route, status_class: statusClass(code) };
    requestsTotal.add(1, labels);
    requestDuration.record(seconds, { service, route });
    if (!res.headersSent) res.status(code).json({ ok: code < 400, service, status: code });
  };
}

// Simulated payment dependency for the checkout path.
async function callPayment() {
  const base = 40 + Math.random() * 60;
  await sleep(base);
  const failed = Math.random() < 0.002; // small intrinsic failure rate
  dependencyCalls.add(1, { dependency: 'payment', status: failed ? 'error' : 'ok' });
  return !failed;
}

app.get('/login', instrument('login', '/login', async (req) => {
  const c = chaos.login;
  await sleep(30 + Math.random() * 40 + c.extraLatencyMs);
  if (Math.random() < c.errorRate) return 500;
  return 200;
}));

app.get('/checkout', instrument('checkout', '/checkout', async (req) => {
  const c = chaos.checkout;
  await sleep(50 + Math.random() * 60 + c.extraLatencyMs);
  if (Math.random() < c.errorRate) return 500;
  const paid = await callPayment();
  return paid ? 200 : 502;
}));

app.get('/healthz', (req, res) => res.json({ status: 'healthy' }));

// Live failure injection: POST { service, errorRate, extraLatencyMs }
app.post('/admin/chaos', (req, res) => {
  const { service, errorRate, extraLatencyMs } = req.body || {};
  if (!chaos[service]) {
    return res.status(400).json({ error: 'service must be login or checkout' });
  }
  if (typeof errorRate === 'number') chaos[service].errorRate = Math.min(Math.max(errorRate, 0), 1);
  if (typeof extraLatencyMs === 'number') chaos[service].extraLatencyMs = Math.max(extraLatencyMs, 0);
  res.json({ service, ...chaos[service] });
});

app.get('/admin/chaos', (req, res) => res.json(chaos));

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`backend listening on ${port}`));
