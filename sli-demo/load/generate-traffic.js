// generate-traffic.js
// Drives steady-state traffic against the frontend to build SLI history.
// Usage: node generate-traffic.js --rps 20 --duration 1800
// Env: TARGET = https://<frontend-app>.azurewebsites.net

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, cur, i, arr) => {
    if (cur.startsWith('--')) acc.push([cur.slice(2), arr[i + 1]]);
    return acc;
  }, [])
);

const target = process.env.TARGET || 'http://localhost:8080';
const rps = Number(args.rps || 20);
const duration = Number(args.duration || 600); // seconds

// 70% checkout (the critical journey), 30% login
const mix = [
  { path: '/api/checkout', weight: 0.7 },
  { path: '/api/login', weight: 0.3 }
];

function pick() {
  const r = Math.random();
  let acc = 0;
  for (const m of mix) { acc += m.weight; if (r <= acc) return m.path; }
  return mix[0].path;
}

let sent = 0, ok = 0, failed = 0;
const start = Date.now();

async function hit() {
  const p = pick();
  sent++;
  try {
    const r = await fetch(target + p);
    if (r.ok) ok++; else failed++;
  } catch {
    failed++;
  }
}

const intervalMs = 1000 / rps;
const timer = setInterval(() => {
  if ((Date.now() - start) / 1000 >= duration) {
    clearInterval(timer);
    console.log(`done. sent=${sent} ok=${ok} failed=${failed}`);
    return;
  }
  hit();
}, intervalMs);

setInterval(() => {
  const elapsed = Math.round((Date.now() - start) / 1000);
  process.stdout.write(`\r[${elapsed}s] sent=${sent} ok=${ok} failed=${failed}   `);
}, 2000);

console.log(`generating ~${rps} rps against ${target} for ${duration}s`);
