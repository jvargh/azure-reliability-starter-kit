// server.js (frontend)
// Serves a minimal store page and proxies login/checkout to the backend API.

require('./telemetry');

const express = require('express');
const path = require('path');

const app = express();
const BACKEND = process.env.BACKEND_URL || 'http://localhost:8080';

app.use(express.static(path.join(__dirname, 'public')));

async function proxy(pathName, res) {
  try {
    const r = await fetch(`${BACKEND}${pathName}`);
    const body = await r.json();
    res.status(r.status).json(body);
  } catch (err) {
    res.status(502).json({ ok: false, error: 'backend unreachable' });
  }
}

app.get('/api/login', (req, res) => proxy('/login', res));
app.get('/api/checkout', (req, res) => proxy('/checkout', res));
app.get('/healthz', (req, res) => res.json({ status: 'healthy' }));

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`frontend listening on ${port}, backend=${BACKEND}`));
