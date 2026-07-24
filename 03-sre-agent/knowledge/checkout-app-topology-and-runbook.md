# Checkout/Login SLI Demo - Architecture and SRE Runbook

This is the authoritative knowledge source for the workload the SRE Agent manages in
resource group `rg-sli-demo` (and the related health model in `rg-healthmodel-demo`).
Read this first when an alert fires so you do not waste cycles rediscovering the layout.

## TL;DR for responders

- The app is a small Node.js e-commerce demo: a **backend** API (`/login`, `/checkout`) plus a
  frontend, an OpenTelemetry collector, and a Prometheus query proxy.
- **Metrics live in the Azure Monitor Workspace (AMW) as Prometheus series, NOT in Application
  Insights.** App Insights receives traces only; there is no classic `requests` table data. Do not
  spend time querying App Insights `requests`/`AppRequests` for request volume or error rate; query
  the AMW Prometheus metrics instead.
- SLI availability = share of `2xx` responses. When it drops below 95% the Sev1 Prometheus alert
  `sli-fast-alerts / CheckoutAvailabilityFastBreach` fires.
- The single most common cause in this environment is an elevated HTTP 500 rate on the `checkout`
  service. The fastest safe mitigation is to **restart the backend App Service**, which clears the
  in-memory fault state and returns availability to ~100%.

## Topology

All resources are in `rg-sli-demo`, region `eastus2`. Names follow the pattern
`slidemo-<role>-<suffix>` (the suffix is random per deployment, e.g. `ioarvugvrpkmc`).

| Role | App Service name | Purpose |
| --- | --- | --- |
| Backend API | `slidemo-be-<suffix>` | Serves `/login`, `/checkout`; calls a simulated `payment` dependency; emits the SLI metrics. Holds the `/admin/chaos` fault-injection endpoint. |
| Frontend | `slidemo-fe-<suffix>` | Simple web UI that calls the backend. |
| OTel collector | `slidemo-otelcolapp-<suffix>` | Receives OTLP from the apps; fans out traces to App Insights and metrics to the AMW. |
| Prometheus proxy | `slidemo-promproxy-<suffix>` | Proxies PromQL queries to the AMW query endpoint (used by dashboards/workbooks). |

Supporting resources: Azure Monitor Workspace `slidemo-amw-<suffix>` (Prometheus metric store),
Log Analytics `slidemo-law-<suffix>` (minimal data), Application Insights `slidemo-ai-<suffix>`
(traces only), action group `ag-sli-demo` (notifications).

## Telemetry pipeline (where to look)

```
apps (OTLP) --> OpenTelemetry Collector --> traces  --> Application Insights (slidemo-ai)
                                        \-> metrics --> Azure Monitor Workspace (slidemo-amw, Prometheus)
```

- **Request rate / error rate / latency = Prometheus metrics in the AMW.** Query them via the AMW
  Prometheus query endpoint (or the promproxy app). The SLI engine (`Microsoft.Monitor/slis`) reads
  the recording-rule metrics below.
- App Insights has distributed traces but no request-count telemetry; treat it as a secondary source.
- Log Analytics has minimal data; do not rely on it for request/error analysis.

### Key metrics and recording rules

Raw counters emitted by the backend (`meter = sli-demo`):

- `http_server_requests_total{service, route, status_class}` - one increment per HTTP response.
  `status_class` is `2xx`, `4xx`, `5xx`, etc.
- `http_server_request_duration_seconds` - request latency histogram (objective boundary at 0.3s).
- `dependency_calls_total{dependency, status}` - downstream calls; `dependency="payment"`,
  `status` is `ok` or `error`.

Recording rules (in prometheus rule group `slidemo-sli-recording-rules`) that the SLIs consume:

- `sli:http_requests:rate5m` = `sum by (service, status_class) (rate(http_server_requests_total[5m]))`
  - Availability numerator = `status_class="2xx"`; denominator = all classes.
- `sli:http_request_latency_good:rate5m` (requests <= 300ms) and
  `sli:http_request_latency_total:rate5m` (all requests) - the latency SLI.
- `sli:dependency_calls:rate5m` = `sum by (dependency, status) (rate(dependency_calls_total[5m]))`
  - Payment dependency SLI: good = `status="ok"`.

### Useful PromQL (run against the AMW)

- Checkout availability percent (matches the alert expression):
  `100 * sum(sli:http_requests:rate5m{service="checkout",status_class="2xx"}) / sum(sli:http_requests:rate5m{service="checkout"})`
- Checkout 5xx rate: `sum(sli:http_requests:rate5m{service="checkout",status_class="5xx"})`
- Payment dependency error rate:
  `sum(sli:dependency_calls:rate5m{dependency="payment",status="error"}) / sum(sli:dependency_calls:rate5m{dependency="payment"})`

## Alerts

- `sli-fast-alerts / CheckoutAvailabilityFastBreach` - Sev1 Prometheus alert on the AMW. Fires when
  checkout `2xx` availability `< 95%` sustained for 1 minute (5m rate window). Auto-resolves ~5 minutes
  after recovery. This is the alert the agent is expected to triage and mitigate.
- SLO burn-rate alerts (1h/6h windows) also exist but are intentionally slow; do not wait on them.

## Common causes and how to triage + mitigate

The `/admin/chaos` endpoint on the backend injects faults for demos. In this environment an SLI
breach is almost always one of the scenarios below. Each maps to a real-world analogue and a concrete
mitigation. Always confirm current fault state first:

`GET https://slidemo-be-<suffix>.azurewebsites.net/admin/chaos` returns the live knobs
`{ login: { errorRate, extraLatencyMs }, checkout: { errorRate, extraLatencyMs } }`.

### 1. Elevated HTTP 500s on checkout (availability SLI drop) - MOST COMMON

- **Symptom:** `CheckoutAvailabilityFastBreach` Sev1; checkout availability well below 95% (for
  example 70-85%); `sli:http_requests:rate5m{service="checkout",status_class="5xx"}` elevated.
- **In this demo:** `chaos.checkout.errorRate > 0` (the backend returns 500 for that fraction of
  requests). Real-world analogue: a bad deploy, an unhandled exception, or a config regression.
- **Triage:** GET `/admin/chaos` (expect a non-zero `checkout.errorRate`); confirm the 5xx rate in
  the AMW; check for a recent deployment to `slidemo-be-<suffix>`.
- **Mitigate (fastest, safe):** restart the backend App Service. This reloads the process and resets
  the in-memory chaos state to `errorRate: 0`, so 500s stop and availability returns to ~100%.
  `az webapp restart --name slidemo-be-<suffix> --resource-group rg-sli-demo`
- **Alternative mitigations:** POST `/admin/chaos { "service": "checkout", "errorRate": 0 }` to clear
  the fault without a restart; or roll back the last backend deployment if a real regression is
  suspected.
- **Verify recovery:** checkout availability climbs back above 95% within a few minutes and the alert
  auto-resolves.

### 2. Elevated latency on checkout or login (latency SLI breach)

- **Symptom:** latency SLI below objective; `sli:http_request_latency_good:rate5m` drops relative to
  `sli:http_request_latency_total:rate5m` (fewer requests under 300ms).
- **In this demo:** `chaos.<service>.extraLatencyMs > 0`. Real-world analogue: a slow dependency,
  resource contention, CPU throttling, or cold starts.
- **Triage:** GET `/admin/chaos` (look for non-zero `extraLatencyMs`); check the latency recording
  rules; check App Service CPU/memory.
- **Mitigate:** restart the backend to clear injected latency; or reset the chaos knob
  (`extraLatencyMs: 0`); if a genuine resource issue, scale the App Service plan up/out.

### 3. Payment dependency failures (dependency SLI drop, checkout 502s)

- **Symptom:** payment dependency SLI drops; checkout returns some `502`s; 
  `sli:dependency_calls:rate5m{dependency="payment",status="error"}` elevated.
- **In this demo:** the payment call has a small intrinsic failure rate and can be amplified by
  checkout chaos. Real-world analogue: a downstream API outage or timeout.
- **Triage:** check the payment dependency error ratio in the AMW; correlate with checkout status.
- **Mitigate:** if driven by injected chaos, reset it / restart the backend; for a real dependency
  outage, verify the downstream service health and fail over or retry with backoff.

### 4. Backend unresponsive or crashing

- **Symptom:** availability collapses across all routes; health check failing.
- **Triage:** check App Service health and logs for `slidemo-be-<suffix>`.
- **Mitigate:** restart the backend App Service; if it does not recover, scale the plan or roll back
  the last deploy.

## Mitigation runbooks (repo)

Ready-made scripts under `03-sre-agent/src/remediation-runbooks/`:

- `disable-chaos.ps1` - resets all chaos knobs on the backend (the safe primary fix for demo faults).
- `restart-backend.ps1` - restarts the backend App Service.
- `scale-plan.ps1 -Instances 3` - scales out the App Service plan.
- `rollback-deploy.ps1` - rolls back the most recent backend deployment.

## Guardrails

- Prefer the least-disruptive fix that restores the SLI: reset the fault or restart the backend before
  scaling or rolling back.
- A restart resets in-memory chaos; if a test harness is still actively injecting chaos it can
  reappear. Confirm no active injection after mitigating.
- After any mitigation, confirm checkout availability is back above 95% and the alert has resolved.
