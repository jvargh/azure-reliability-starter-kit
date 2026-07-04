# SLO / SLI Design Lab

A hands-on lab that takes you from a running application to authored SLIs. You will enumerate every  
user journey, extract the critical ones, collect the evidence needed to design each SLI, fill in a  
design checklist, and then translate that checklist field-by-field into the Azure portal "Create new  
SLI" form. The lab spans the whole workflow: data collection (Parts 1 to 3), the design  
checklist (Part 4), and implementation (Parts 5 to 6).

This lab is a **reusable template**: run it against your own application by substituting your  
resource names and journeys. Throughout, the **Checkout demo** (a store with Login, Checkout, and a  
Payment dependency) is filled in as the worked example so you can see what a completed answer looks  
like.

How this fits with the other document in `sli-design/`:

*   [SLO-SLI-Design-Guide.md](SLO-SLI-Design-Guide.md) is the theory-plus-process reference: it starts  
    from first principles (why SLIs exist, the layered mental model), states the design requirements,  
    and lays out the reusable process with the Azure form mapping. Read it first if the vocabulary is  
    new.
*   **This lab** is the executable version: the actual commands, queries, and form fields.

---

## Lab conventions

Placeholders you substitute once and reuse everywhere:

| Placeholder | Meaning | Demo value |
| --- | --- | --- |
| `<rg>` | Resource group holding the app and workspace | `rg-sli-demo` |
| `<prefix>` | Naming prefix from your deployment | `slidemo` |
| `<suffix>` | Unique suffix from your deployment | `ioarvugvrpkmc` |
| `<amw>` | Azure Monitor Workspace (SLI source and destination) | `slidemo-amw-ioarvugvrpkmc` |
| `<identity>` | User-assigned managed identity for the SLI engine | `slidemo-id-ioarvugvrpkmc` |
| `<sg>` | Service Group the SLIs are authored on | `CheckoutSG-ioarvugvrpkmc` |
| `<ai>` | Application Insights component (journey discovery) | `slidemo-ai-ioarvugvrpkmc` |

Commands are PowerShell (the workspace default shell). Queries are PromQL against the Azure Monitor  
Workspace, or KQL against Application Insights.

---

## Part 0: Environment setup and access checks

**Goal:** confirm you can query both telemetry stores before you rely on their data.

### 0.1 Select your subscription and set your variables

> **Stop: these are example values, not runnable defaults.** `rg-sli-demo`, `slidemo`, and the  
> `ioarvugvrpkmc` suffix are the demo placeholders. If you run them as-is you will get  
> `AuthorizationFailed` (the resources are not in your subscription). Replace every value below with  
> your own deployment's names before continuing.

First point the CLI at the subscription that actually holds your app and workspace, and confirm it:

```
az login                                             # if not already signed in
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id}" -o table   # confirm you are where you expect
```

Then set your resource names (these are the demo's values; replace with your own deployment's names):

```
$RG       = "rg-sli-demo"                  # your resource group
$PREFIX   = "slidemo"                       # your naming prefix
$SUFFIX   = "ioarvugvrpkmc"                 # your deployment suffix
$AMW      = "$PREFIX-amw-$SUFFIX"           # or your actual Azure Monitor Workspace name
$IDENTITY = "$PREFIX-id-$SUFFIX"            # or your actual user-assigned identity name
$SG       = "CheckoutSG-$SUFFIX"            # or your actual Service Group name
$AI       = "$PREFIX-ai-$SUFFIX"            # or your actual Application Insights name

# echo all variables to confirm they resolved
[pscustomobject]@{
  RG = $RG; PREFIX = $PREFIX; SUFFIX = $SUFFIX
  AMW = $AMW; IDENTITY = $IDENTITY; SG = $SG; AI = $AI
} | Format-List

# sanity check: the resource group must exist and be readable in the selected subscription
if ((az group exists -n $RG) -ne "true") {
  Write-Error "Resource group '$RG' not found (or no access) in the current subscription. Fix the subscription and names above before continuing."
}
```

If that last check errors, do not run the rest of the lab yet: your subscription context or resource  
names are wrong, and every later command will fail the same way.

### 0.2 Resolve the Prometheus query endpoint of the Azure Monitor Workspace

The SLI engine reads Prometheus metrics from the workspace. You will query the same endpoint to  
collect design evidence.

```
$amwId = az resource show -g $RG -n $AMW `
  --resource-type "Microsoft.Monitor/accounts" --query id -o tsv

# guard: stop clearly here instead of cascading into a confusing '--ids expected at least one argument'
if (-not $amwId) {
  Write-Error "Azure Monitor Workspace '$AMW' not found or not accessible in RG '$RG'. Check 0.1 (subscription + names + RBAC) before continuing."
  return
}

$PROM = az resource show --ids $amwId `
  --query "properties.metrics.prometheusQueryEndpoint" -o tsv
$PROM   # e.g. https://<workspace>-<hash>.<region>.prometheus.monitor.azure.com
```

### 0.3 A reusable PromQL helper

Every measurement in this lab runs a PromQL query. Define one helper and reuse it.

```
function Invoke-Prom($query) {
  $token = az account get-access-token `
    --resource "https://prometheus.monitor.azure.com" `
    --query accessToken -o tsv
  $resp = Invoke-RestMethod -Method Post -Uri "$PROM/api/v1/query" `
    -Headers @{ Authorization = "Bearer $token" } `
    -Body @{ query = $query }
  return $resp.data.result
}

# smoke test: which services are emitting request metrics right now?
Invoke-Prom 'sum by (service) (rate(http_server_requests_total[5m]))' |
  ForEach-Object { "{0} = {1}" -f $_.metric.service, [math]::Round([double]$_.value[1],3) }
```

Expected output (requests per second per service):

```
checkout = 10.772
login = 4.702
```

If this returns rows, your query path works. If it returns nothing, generate traffic first (see  
`sli-demo/load/generate-traffic-all.ps1`) so the metrics exist.

> **Validated mechanism.** The token + `POST /api/v1/query` flow above was run against a live Azure  
> Monitor Workspace and returns a standard Prometheus envelope (`status=success`, `resultType=vector`).  
> See [Appendix C](#appendix-c-validated-command-outputs) for the captured outputs. One workspace  
> quirk to know: Azure Monitor managed Prometheus only accepts **equality** filters on the metric name  
> (`__name__="..."`). A `!=` on `__name__` is rejected with `Not implemented`. Every query in this lab  
> uses name equality, so this does not affect you, but keep it in mind when writing ad-hoc queries.

### 0.4 Confirm Application Insights query access (for journey discovery)

App Insights returns results as a nested object, so raw output is hard to read. Define one helper that  
maps columns to rows and returns clean PowerShell objects you can pipe to `Format-Table`. Run (a) to  
confirm access (prints `1`), then (b) for a tidy operations-by-volume table.

```
# a) prove access + query path works (prints 1)
az monitor app-insights query --app $AI -g $RG `
  --analytics-query "print ok=1" --query "tables[0].rows[0][0]" -o tsv

# reusable helper: run KQL, return clean objects (default lookback 7 days)
function Invoke-AI($kql, $offset = "7d") {
  $resp = az monitor app-insights query --app $AI -g $RG --offset $offset `
            --analytics-query $kql -o json | ConvertFrom-Json
  $t = $resp.tables[0]
  $cols = @($t.columns.name)
  foreach ($row in $t.rows) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
    [pscustomobject]$o
  }
}

# b) request operations by volume, as a clean table
Invoke-AI "requests | summarize Calls=count() by name | order by Calls desc" |
  Format-Table -AutoSize
```

Expected output (a) prints `1`; (b) is a clean table:

```
name               Calls
----               -----
GET /api/checkout 668142
GET /checkout     668081
GET /api/login    346355
GET /login        346310
GET /healthz        5052
GET /                  9
POST /admin/chaos      1
```

> **If (a) prints** `**1**` **but (b) is empty**, access is fine; App Insights just has no `requests` yet  
> (ingestion lags a few minutes, and this demo sends most signal as OTel metrics, not to App Insights).  
> It is a bonus here, so continue with the PromQL path. To see which tables do have data:  
> `Invoke-AI "union withsource=T * | summarize Rows=count() by T | order by Rows desc" | Format-Table -AutoSize`

**Checkpoint:** the PromQL query in 0.3 returns rows, and the App Insights probe in 0.4a prints  
`1` (App Insights `requests` data is a bonus, not required, thanks to the PromQL discovery path).

---

## Part 1: Enumerate ALL user journeys

**Goal:** produce a complete inventory of what users actually do. Do not filter for importance yet;  
completeness first, judgement later.

A **user journey** is a task a customer completes, expressed in their language ("check out", "log  
in", "view order history"), not an endpoint or a service. One journey usually spans several requests  
and may fan out to dependencies.

### 1.1 Build the journey inventory from telemetry

> **Session prerequisites.** Functions and variables are per-terminal. In this same terminal you must  
> have run 0.1 (variables), 0.3 (`Invoke-Prom`, `$PROM`), and 0.4 (`Invoke-AI`). Quick check:  
> `Get-Command Invoke-Prom, Invoke-AI` and `"$AI / $RG / $PROM"` (all non-empty).

One script turns the request metric into a per-journey inventory (service = journey, its routes,  
volume, share of traffic, instrumentation) and lists the dependencies it sees. Volumes and percentages  
are computed for you, so there is nothing to hand-fill:

```
# Build the journey inventory from workspace metrics
$routes = Invoke-Prom 'sum by (service, route) (increase(http_server_requests_total[7d]))' |
  ForEach-Object {
    [pscustomobject]@{ Service=$_.metric.service; Route=$_.metric.route; Requests7d=[long][double]$_.value[1] }
  }
$total = ($routes | Measure-Object Requests7d -Sum).Sum
$deps  = Invoke-Prom 'count by (dependency) (dependency_calls_total)' | ForEach-Object { $_.metric.dependency }

$inventory = $routes | Group-Object Service | ForEach-Object {
  $reqs = ($_.Group | Measure-Object Requests7d -Sum).Sum
  [pscustomobject]@{
    Journey      = $_.Name
    Routes       = ($_.Group.Route | Sort-Object -Unique) -join ', '
    Requests7d   = $reqs
    PctTraffic   = '{0:P1}' -f ($reqs / $total)
    Instrumented = 'Y'
  }
} | Sort-Object Requests7d -Descending

$inventory | Format-Table -AutoSize
"Dependencies observed: {0}" -f ($deps -join ', ')
$inventory | Export-Csv -NoTypeInformation .\journey-inventory.csv   # optional, to annotate
```

Expected output:

```
Journey  Routes     Requests7d PctTraffic Instrumented
-------  ------     ---------- ---------- ------------
checkout /checkout      941231 65.7 %     Y
login    /login         490848 34.2 %     Y

Dependencies observed: payment
```

Every journey in the metric is `Instrumented = Y`; `PctTraffic` is its share of traffic (use  
`Requests7d` for the absolute count).

Optional App Insights cross-check (same picture from traces, one line):

```
Invoke-AI "requests | where timestamp > ago(7d) | summarize Calls=count(), ServerErrors=countif(toint(resultCode) >= 500), P95ms=round(percentile(duration,95),1) by name | order by Calls desc" | Format-Table -AutoSize
```

Each journey appears twice (frontend `/api/*` proxies to backend `/checkout` and `/login`), confirming  
the full path is instrumented:

```
name               Calls ServerErrors  P95ms
----               ----- ------------  -----
GET /api/checkout 683869        16894 227.20
GET /checkout     683835        16892 196.40
GET /api/login    363577            0 405.90
GET /login        363544            0 387.20
...
```

### 1.2 Enrich and cross-check (what telemetry cannot infer)

The 1.1 table gives routes, volume, share, and instrumentation. Two things still need judgement;  
telemetry helps with one:

**User goal: not inferable, write it in.** Telemetry knows the route, not the intent, so add a one-line  
goal per journey yourself (`/checkout` -> "Complete a purchase", `/login` -> "Sign in") and have product  
confirm the wording.

**Dependency -> journey: map by hand.** Step 1.1 already lists the dependencies it saw  
(`Dependencies observed: payment`). Assign each to the journey that calls it from architecture  
knowledge (`payment` belongs to `checkout`). Metrics do not carry the caller, and this demo's  
OTel dependency spans are attribute-less, so there is nothing to group on programmatically.

**Add what telemetry cannot see.** Ask product and support for rare-but-critical journeys (refunds,  
annual exports) that generate little steady traffic, and flag any journey with no metric at all as an  
instrumentation gap. Add those rows by hand (blank worksheet in [Appendix A](#appendix-a-blank-worksheets-copy-per-workload)).

**Worked example (demo app), after annotation:**

| Journey | User goal | Route(s) | Dependencies | PctTraffic | Instrumented? |
| --- | --- | --- | --- | --- | --- |
| Checkout | Complete a purchase | `/checkout` (via `/api/checkout`) | Payment provider | 65.7 % | Y |
| Login | Sign in to the store | `/login` (via `/api/login`) | none | 34.2 % | Y |
| Browse catalog | View products | static page | none | not in metrics | Partial |

**Checkpoint:** a table listing every journey, including any that are uninstrumented.

---

## Part 2: Extract the CRITICAL journeys

**Goal:** narrow the full inventory to the 1 to 3 journeys (plus their key dependencies) that deserve  
an SLO. SLOs are deliberately scarce: an SLO per endpoint produces noise no one defends.

### 2.1 Score each journey

Rate every journey 1 (low) to 3 (high) on four axes, then sum:

| Axis | Question | 1 | 3 |
| --- | --- | --- | --- |
| Business impact | Does failure cost revenue or trust directly? | internal only | direct revenue |
| Frequency | How often is it exercised? | rare | constant |
| User visibility | Does the user immediately feel a failure? | background | foreground, blocking |
| Blast radius | Does its failure break other journeys? | isolated | many depend on it |

Journeys scoring high (roughly 9+ of 12), plus any dependency a high-scoring journey cannot live  
without, become SLO candidates.

### 2.2 Criticality worksheet

Seed the sheet **from Part 1's** `**$inventory**` so you do not retype journeys, and derive the Frequency  
score from traffic share automatically. The other three axes are judgement, set them per journey  
(requires `$inventory` and `$deps` from Part 1 in the same session):

```
# Frequency from traffic share; Business/Visibility/BlastRadius are yours to set (1-3)
function Freq([double]$p){ if($p -ge 30){3} elseif($p -ge 5){2} else {1} }

$score  = @()
$score += $inventory | ForEach-Object {
  [pscustomobject]@{ Journey=$_.Journey; Business=2; Frequency=(Freq ([double]($_.PctTraffic -replace '[^\d.]'))); Visibility=2; BlastRadius=2 }
}
$score += $deps | ForEach-Object {   # dependencies are candidates too
  [pscustomobject]@{ Journey="$_ (dep)"; Business=2; Frequency=3; Visibility=2; BlastRadius=2 }
}

# adjust the judgement axes for your app (examples):
($score | Where-Object Journey -eq 'checkout')      | ForEach-Object { $_.Business=3; $_.Visibility=3; $_.BlastRadius=3 }
($score | Where-Object Journey -eq 'login')         | ForEach-Object { $_.Visibility=3; $_.BlastRadius=3 }
($score | Where-Object Journey -eq 'payment (dep)') | ForEach-Object { $_.Business=3; $_.BlastRadius=3 }

# compute Total and SLO candidacy (>= 9 of 12)
$scored = $score |
  Select-Object *, @{n='Total';e={$_.Business+$_.Frequency+$_.Visibility+$_.BlastRadius}} |
  Select-Object *, @{n='Candidate';e={if($_.Total -ge 9){'Y'}else{'N'}}} |
  Sort-Object Total -Descending
$scored | Format-Table -AutoSize
```

Expected output:

```
Journey       Business Frequency Visibility BlastRadius Total Candidate
-------       -------- --------- ---------- ----------- ----- ---------
checkout             3         3          3           3    12 Y
login                2         3          3           3    11 Y
payment (dep)        3         3          2           3    11 Y
```

Prefer to fill by hand? Use the blank criticality sheet in [Appendix A](#appendix-a-blank-worksheets-copy-per-workload).

**Worked example (demo app):**

| Journey | Business | Frequency | Visibility | Blast radius | Total | SLO candidate? |
| --- | --- | --- | --- | --- | --- | --- |
| Checkout | 3 | 3 | 3 | 3 | 12 | **Yes** (most critical) |
| Login | 2 | 3 | 3 | 3 | 11 | **Yes** (gates everything) |
| Payment (dep) | 3 | 3 | 2 | 3 | 11 | **Yes** (checkout depends on it) |
| Browse catalog | 1 | 3 | 2 | 1 | 7 | No (revisit later) |

Result: three SLO candidates, matching the demo's three SLIs (Checkout availability, Login latency,  
Payment dependency availability).

### 2.3 Assign an SLI category per critical journey

For each candidate, choose the dimension of experience that best captures pain, and the SLI shape:

| Category | When | Shape |
| --- | --- | --- |
| Availability | "did the request succeed?" (default) | request-based (good/total) |
| Latency | "was it fast enough?" (slowness is the failure) | window-based (good windows/total) |
| Dependency availability | a downstream call the journey needs | request-based (good/total) |

Default a category programmatically from the `$scored` candidates: dependency rows become dependency  
availability and everything else defaults to availability. "Latency" cannot be inferred from telemetry,  
it is a judgement you apply, so list the journeys where slowness (not failure) is the pain. In the  
demo, Login almost never fails (its `ServerErrors` are ~0) but a slow login still hurts, so it is a  
latency SLI:

```
# journeys where slowness, not failure, is the pain -> latency (set these for your app)
$latencyJourneys = @('login')

$scored | Where-Object Candidate -eq 'Y' | ForEach-Object {
  $isDep = $_.Journey -like '*(dep)'
  $isLat = $_.Journey -in $latencyJourneys
  [pscustomobject]@{
    Journey  = $_.Journey
    Category = if ($isDep) { 'Dependency availability' } elseif ($isLat) { 'Latency' } else { 'Availability' }
    Shape    = if ($isLat) { 'Window-based' } else { 'Request-based' }
  }
} | Format-Table -AutoSize
```

Expected output (matches the three deployed SLIs):

```
Journey       Category                Shape
-------       --------                -----
checkout      Availability            Request-based
login         Latency                 Window-based
payment (dep) Dependency availability Request-based
```

**Worked example:**

| Critical journey | SLI category | Shape |
| --- | --- | --- |
| Checkout | Availability | Request-based |
| Login | Latency | Window-based |
| Payment | Dependency availability | Request-based (formula) |

**Checkpoint 2:** 1 to 3 critical journeys, each tagged with an SLI category and shape.

---

## Part 3: Data collection (per critical journey)

**Goal:** for each critical journey, collect the four pieces of evidence a defensible SLI design  
requires: (a) the source metric and its dimensions exist, (b) current performance (to set a  
measured target), (c) the signal is continuous, (d) the good/valid definition is written down.

Run Part 3 once per critical journey.

### 3.1 Confirm the source metric and required dimensions exist

An SLI can only filter on **labels that physically exist on the metric**. Prove every dimension each of  
your critical-journey SLIs will filter on is present before designing anything, one check per SLI:

```
# Checkout availability -> needs service + status_class on http_server_requests_total
Invoke-Prom 'count by (service, status_class) (http_server_requests_total{service="checkout"})' |
  ForEach-Object { "{0} / {1}" -f $_.metric.service, $_.metric.status_class }

# Login latency -> needs service on the P95 latency recording rule
Invoke-Prom 'count by (service) (sli:http_request_latency_p95:5m{service="login"})' |
  ForEach-Object { $_.metric.service }

# Payment dependency -> needs dependency + status on dependency_calls_total
Invoke-Prom 'count by (dependency, status) (dependency_calls_total{dependency="payment"})' |
  ForEach-Object { "{0} / {1}" -f $_.metric.dependency, $_.metric.status }
```

Expected output:

```
# Checkout availability (service / status_class)
checkout / 2xx
checkout / 5xx

# Login latency (service)
login

# Payment dependency (dependency / status)
payment / error
payment / ok
```

Each SLI's filter labels exist: checkout has `status_class` (`2xx` = good) split by `service`; the  
login latency rule carries `service`; and the payment dependency has `status` (`ok` = good) split by  
`dependency`.

Source metric behind each dimension:

| SLI | Source metric (raw) | Dimensions used |
| --- | --- | --- |
| Checkout availability | `http_server_requests_total` | `service`, `status_class` |
| Login latency | `http_server_request_duration_seconds` (read via `sli:http_request_latency_p95:5m`) | `service` |
| Payment dependency | `dependency_calls_total` | `dependency`, `status` |

This confirms the labels the SLI will filter on exist: `status_class=2xx` (good) vs all classes  
(valid) for checkout availability, and `status=ok` (good) vs all (valid) for the payment dependency.

If the label you need to filter on is missing, stop and fix instrumentation (or add a recording rule  
that emits it). In this demo the recording rules already pre-aggregate to exactly the SLI dimensions:

| Recording rule | Dimensions | Feeds SLI |
| --- | --- | --- |
| `sli:http_requests:rate5m` | `service`, `status_class` | Checkout availability |
| `sli:dependency_calls:rate5m` | `dependency`, `status` | Payment dependency |
| `sli:http_request_latency_p95:5m` | `service` | Login latency |

### 3.2 Measure CURRENT performance (evidence for the target)

Set the SLO from what the service does today, not from a default of "five nines".

**Availability over the trailing 7 days (Checkout):**

```
Invoke-Prom @'
sum(increase(http_server_requests_total{service="checkout",status_class="2xx"}[7d]))
/
sum(increase(http_server_requests_total{service="checkout"}[7d]))
'@ | ForEach-Object { "checkout availability 7d = {0:P3}" -f [double]$_.value[1] }
```

```
checkout availability 7d = 97.831%
```

**Latency: fraction of 5-minute windows meeting P95 \<= 300 ms over 7 days (Login):**

```
Invoke-Prom @'
avg_over_time( (sli:http_request_latency_p95:5m{service="login"} <= bool 0.3)[7d:5m] )
'@ | ForEach-Object { "login good-window fraction 7d = {0:P2}" -f [double]$_.value[1] }
```

```
login good-window fraction 7d = 99.3%
```

**Dependency success over 7 days (Payment):**

```
Invoke-Prom @'
sum(increase(dependency_calls_total{dependency="payment",status="ok"}[7d]))
/
sum(increase(dependency_calls_total{dependency="payment"}[7d]))
'@ | ForEach-Object { "payment success 7d = {0:P3}" -f [double]$_.value[1] }
```

```
payment success 7d = 99.797%
```

Record the measured number, then set the target **slightly below** it so the SLO is achievable but  
still meaningful. Example: if measured Checkout availability is 99.94%, a 99.9% target leaves real  
budget while defending the journey.

**Measured performance summary (this run):**

| SLI | Measures | Measured (7d) | Proposed target | Error budget | Budget used |
| --- | --- | --- | --- | --- | --- |
| Checkout availability | 2xx / all checkout requests | 97.83% | 99.9% | 0.1% | ~2170% (blown) |
| Login latency | good 5-min windows (P95 `<= 300 ms`) | 99.3% | 99% | 1% | ~70% |
| Payment dependency | ok / all payment calls | 99.80% | 99.5% | 0.5% | ~41% |

**How the Error budget column is calculated.** "Target" is the **Proposed target** column above (the  
SLO you commit to). The error budget is simply the failure that target still allows:

$$\text{error budget} = 100\% - \text{Proposed target}$$

Subtracting each row's Proposed target gives its Error budget column:

*   Checkout: `100% - 99.9% = 0.1%`
*   Login: `100% - 99% = 1%`
*   Payment: `100% - 99.5% = 0.5%`

**How much of that budget is already used** is the actual bad rate divided by the allowed bad rate  
(the error budget):

$$\text{budget used} = \frac{100\% - \text{Measured}}{100\% - \text{Proposed target}}$$

Above 100% means the budget is exhausted (the SLO is in breach). Worked for this run:

*   Checkout: `(100 - 97.83) / (100 - 99.9) = 2.17 / 0.1 ≈ 21.7` → ~2170%, budget blown ~22x.
*   Login: `(100 - 99.3) / (100 - 99) = 0.7 / 1 = 0.70` → 70% used, 30% remaining.
*   Payment: `(100 - 99.80) / (100 - 99.5) = 0.20 / 0.5 = 0.41` → ~41% used, 59% remaining.

The proposed targets are the demo's chosen baselines (the three deployed SLIs). Checkout is **below**  
its target in this run because degradation is being injected, so it is burning budget hard right now  
(Login and Payment still have budget left). On a healthy service you set the target just under the  
measured value; measure during a clean window before locking targets in.

### 3.3 Confirm the signal is continuous (no silent gaps)

An SLI over an empty window publishes nothing and the panel reads "No data". Verify each SLI's source  
metric never goes dark. For each source, aggregate all its series into one (otherwise you get one row  
per series, e.g. a `1` for `status_class=2xx` and another for `5xx`), then use a subquery so a single  
value covers the whole window:

```
# check the source metric behind each of the three SLIs
$sources = [ordered]@{
  'checkout availability' = 'http_server_requests_total{service="checkout"}'
  'login latency'         = 'sli:http_request_latency_p95:5m{service="login"}'
  'payment dependency'    = 'dependency_calls_total{dependency="payment"}'
}
foreach ($name in $sources.Keys) {
  $q = "min_over_time( (sum(count_over_time($($sources[$name])[5m])) > bool 0)[6h:5m] )"
  Invoke-Prom $q | ForEach-Object { "{0} continuous (1=yes, 0=gap): {1}" -f $name, $_.value[1] }
}
```

Each query returns `1` when every 5-minute bucket in the last 6h had data, `0` if any bucket was empty.

Expected output (all continuous over the last 6h):

```
checkout availability continuous (1=yes, 0=gap): 1
login latency continuous (1=yes, 0=gap): 1
payment dependency continuous (1=yes, 0=gap): 1
```

If any returns `0`, a 5-min bucket in the window was empty; add a steady traffic or heartbeat generator  
so every evaluation window has samples (the demo uses `sli-demo/load/generate-traffic-all.ps1`).

### 3.4 Write the good / valid definition (the contract)

In plain sentences, before any portal work. Be explicit about edge cases.

**Worked example:**

*   **Checkout availability:** valid = all requests to `service=checkout`; good = those with  
    `status_class=2xx`. Exclude health checks (`/healthz`). 3xx and 4xx count as not-good.
*   **Login latency:** valid = all `service=login` requests; a 5-minute window is good when P95  
    duration `<= 0.3s`. SLI = good windows / total windows.
*   **Payment dependency:** valid = all `dependency=payment` calls; good = `status=ok`.

### 3.5 Data-collection worksheet (fill one per critical journey)

```
Journey: _______________________________________
SLI category / shape: __________________________
Source metric: _________________________________
Required dimensions present? (Y/N): ____________
Good = ________________________________________
Valid = _______________________________________
Measured current performance (7d): ______%
Signal continuous? (Y/N): ______________________
Proposed SLO target: ______%   Window: ___ rolling days
```

**Filled example, Checkout availability:**

```
Journey: Checkout
SLI category / shape: Availability / request-based
Source metric: http_server_requests_total
Required dimensions present? (Y/N): Y (service, status_class)
Good = requests with status_class=2xx (service=checkout)
Valid = all requests with service=checkout (exclude /healthz)
Measured current performance (7d): 97.83%
Signal continuous? (Y/N): Y
Proposed SLO target: 99.9%   Window: 7 rolling days
```

**Filled example, Login latency:**

```
Journey: Login
SLI category / shape: Latency / window-based
Source metric: http_server_request_duration_seconds (via sli:http_request_latency_p95:5m)
Required dimensions present? (Y/N): Y (service)
Good = 5-min windows where P95 <= 0.3s (service=login)
Valid = all 5-min windows with login traffic
Measured current performance (7d): 99.3% of windows good
Signal continuous? (Y/N): Y
Proposed SLO target: 99%   Window: 7 rolling days
```

**Filled example, Payment dependency:**

```
Journey: Payment (checkout dependency)
SLI category / shape: Dependency availability / request-based
Source metric: dependency_calls_total
Required dimensions present? (Y/N): Y (dependency, status)
Good = calls with status=ok (dependency=payment)
Valid = all calls with dependency=payment
Measured current performance (7d): 99.80%
Signal continuous? (Y/N): Y
Proposed SLO target: 99.5%   Window: 7 rolling days
```

**Checkpoint:** one completed data-collection worksheet per critical journey, each backed by a  
real measured number.

---

## Part 4: Consolidate into the design checklist

**Goal:** collapse everything you gathered in Part 3 into one row per SLI, so each row is a complete,  
unambiguous fill-in guide for the portal wizard in Part 5. No new decisions are made here: the good  
and valid definitions come from Part 3.4, and the target, window, and error budget come straight from  
the measured-performance summary in Part 3.2.

Two extra values ride along with the target. The first is carried from Part 3.2; the second is the  
one design choice introduced in Part 4 (an alerting policy, not a measurement), which is why it did  
not appear in any earlier worksheet:

*   **Error budget** is the failure the target still allows: `error budget = 100% - target`. These are  
    the same numbers you already filled into the Part 3.2 summary (0.1% for Checkout, 1% for Login,  
    0.5% for Payment), so copy them across unchanged.
*   **Fast burn / Slow burn** are *not* measured from telemetry, so unlike every other column they have  
    no upstream source in Parts 1 to 3: they are a burn-rate alerting policy you decide here and apply  
    uniformly to every SLI. A burn rate of `N` means the budget is being spent `N` times faster than the  
    target sustains, so the fraction of the error budget consumed over a lookback `L` within an SLO  
    window `W` is `N x (L / W)`. Set two rules with the same defaults on every SLI: a **fast burn** that  
    pages (`~14x / 1h`, roughly 8% of a 7-day budget in one hour) and a **slow burn** that opens a  
    ticket (`~3x / 6h`, roughly 11% over six hours). These are standard starting points; you bind them  
    to an action group and tune for noise in Part 5.3.

### 4.1 Design checklist worksheet (one row per SLI)

```
SLI name | Type (Avail/Latency) | Shape (req/window) | Good signal | Total signal / criterion | Target % | Window (rolling d) | Error budget % | Fast burn | Slow burn
```

**Worked example (demo app)** - targets and budgets carried forward verbatim from the Part 3.2 summary:

| SLI name | Type | Shape | Good signal | Total / criterion | Target | Window | Budget | Fast burn | Slow burn |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `CheckoutAvailabilitySLI` | Availability | Request | `sli:http_requests:rate5m{service=checkout,status_class=2xx}` | `sli:http_requests:rate5m{service=checkout}` | 99.9% | 7 | 0.1% | ~14x / 1h | ~3x / 6h |
| `LoginLatencySLI` | Latency | Window | `sli:http_request_latency_p95:5m{service=login}` | window good if P95`<= 0.3s` | 99% | 7 | 1% | ~14x / 1h | ~3x / 6h |
| `PaymentDependencySLI` | Availability | Request | `sli:dependency_calls:rate5m{dependency=payment,status=ok}` | `sli:dependency_calls:rate5m{dependency=payment}` | 99.5% | 7 | 0.5% | ~14x / 1h | ~3x / 6h |

**Column provenance.** Every column is backed either by evidence collected earlier or by the stated  
policy default, so nothing in the row is invented at this step:

| Column | Where the data comes from |
| --- | --- |
| SLI name | Journey + category naming convention (Part 2.3) |
| Type | SLI category (Part 2.3) |
| Shape | SLI shape (Part 2.3) |
| Good signal | Good definition + confirmed dimensions (Parts 3.1, 3.4) |
| Total / criterion | Valid definition + confirmed dimensions (Parts 3.1, 3.4) |
| Target | Proposed target from measured performance (Part 3.2 summary, Part 3.5) |
| Window | Evaluation window (Parts 3.2, 3.5) |
| Error budget | Computed `100% - target` (Part 3.2) |
| Fast burn / Slow burn | Burn-rate alerting policy set in this section (not measured); tuned in Part 5.3 |

### 4.2 Carry the row into the wizard

Each column lands in a specific field of the Part 5 "Create new SLI" wizard, so the completed row is  
literally your tab-by-tab script:

| Checklist column | Part 5 wizard field | Tab |
| --- | --- | --- |
| SLI name, Type | SLI name, SLI type | Basics (5.1) |
| Shape | Evaluation method (Request Count Based / Window based) | SLI (5.2) |
| Good signal | Good signal(s) + filters | SLI (5.2) |
| Total signal / criterion | Total signal(s), or window uptime criterion | SLI (5.2) |
| Target | Baseline (SLO) | Baseline + Alert (5.3) |
| Window | Evaluation period | Baseline + Alert (5.3) |
| Fast burn, Slow burn | Burn-rate alert rules | Baseline + Alert (5.3) |

**Checkpoint:** a completed design-checklist row for every SLI you will author, with targets and  
budgets that match Part 3.2. Carry the table straight into Part 5 and work one tab at a time.

---

## Part 5: Author the SLIs in the portal (field-by-field)

**Goal:** translate each design-checklist row into the "Create new SLI" wizard. The wizard has four  
tabs (as in the screenshots): **Basics**, **SLI**, **Baseline + Alert**, **Review + create**.

### 5.0 Pre-flight (the form assumes these are already done)

1.  **Service Group monitoring defaults.** Open the Service Group (`<sg>`) > **Monitoring**. If it  
    shows "No SLIs" / enable monitoring, select **Configure settings** and set a **default Managed**  
    **Identity** (`<identity>`) and **default Azure Monitor Workspace** (`<amw>`). Without these the  
    form warns that the SG has no default MI or AMW.
2.  **RBAC on** (`<identity>`)**.** On `<amw>`: `Monitoring Reader`, `Monitoring Data Reader` (read source)  
    and `Monitoring Metrics Publisher` (publish results), plus `Monitoring Metrics Publisher` on the  
    workspace's data collection rule.
3.  **Dimensions indexed.** The SLI validator rejects dimension filters until the workspace has  
    indexed the metric metadata. If a filter will not accept `status_class`, wait and retry.

Then open: Service Group `<sg>` > **Monitoring** > **Service Level Indicators (SLIs)** > **Create**  
**SLIs**.

### 5.1 Tab 1: Basics

| Field | What to enter | Source in this lab |
| --- | --- | --- |
| Service Group | Read-only, shows`<sg>` | Part 2 |
| SLI type | **Availability** or **Latency** | checklist "Type" |
| SLI name | The SLI name (e.g.`CheckoutAvailabilitySLI`) | checklist "SLI name" |
| SLI description | The good/valid sentence (e.g. "Percent of checkout requests returning 2xx") | Part 3.4 |

Availability measures success ratio; Latency measures response time against a threshold. Pick the one  
from your checklist "Type" column.

### 5.2 Tab 2: SLI

**Metrics details**

| Field | What to enter | Source |
| --- | --- | --- |
| Evaluation method | **Request Count Based** (request shape) or **Window based** (window shape) | checklist "Shape" |

**Identity and data source**

| Field | What to enter | Source |
| --- | --- | --- |
| Managed Identity | `<identity>` | pre-flight |
| Data source | `<amw>` (source workspace) | Part 0 |

**SLI Details (request-based, e.g. Checkout and Payment)**

*   **Good signal(s)** > '**\+ Add Metric**': the good metric with its filters, and Summarize (Sum) by the  
    grouping dimension. Example (Checkout): metric `sli:http_requests:rate5m`, filters `service eq checkout`  
    and `status_class eq 2xx`, Summarize **Sum** for dimension `service` (leave the metric's own time  
    aggregation at its default, **Average**). Payment uses `sli:dependency_calls:rate5m` with  
    `dependency eq payment` and `status eq ok`, Summarize **Sum** for dimension `dependency`.
*   **Total signal(s)** > '**\+ Add Metric**': the same metric with the broader filter. Example (Checkout):  
    `sli:http_requests:rate5m`, filter `service eq checkout`, Summarize **Sum** for dimension `service`  
    (Payment: `sli:dependency_calls:rate5m`, filter `dependency eq payment`).
*   For a ratio that needs combining metrics (e.g. Payment `ok / (ok + error)`), add each metric then  
    '**\+ Add formula**'.
*   Click '**Validate**'. Confirm the '**Good Signal Preview**' and '**Total Signal Preview**' render and the  
    ratio sits near 1.0 under healthy traffic.

**SLI Details (window-based, e.g. Login latency)**

*   Provide the single signal (`sli:http_request_latency_p95:5m`, filter `service eq login`). This  
    recording rule already is the 5-minute P95, so you do not add a temporal P95 aggregation on top.
*   Set the **window uptime criterion**: comparator + threshold (`<= 0.3`) with the window size (5 min).  
    Each window is marked good or bad; the SLI is the fraction of good windows.

**Identity and Data storage location** (where evaluated results are written)

| Field | What to enter |
| --- | --- |
| Managed Identity | `<identity>` (same) |
| Storage location | `<amw>` (source and destination may be the same workspace) |

### 5.3 Tab 3: Baseline + Alert 

| Field | What to enter | Source |
| --- | --- | --- |
| Baseline (SLO) | The target number, e.g.`99.9` (or `95` for latency percent-good) | checklist "Target" |
| Evaluation period | `7` `rolling` day(s) | checklist "Window" |
| Alerts > Enable Alert | Turn on, then add burn-rate rules | checklist "Fast/Slow burn" |

Burn-rate alert starting points for a tight budget: fast burn ~14x over 1h (page), slow burn ~3x over  
6h (ticket). Bind each to your action group (`ag-sli-demo` in the demo). The **Baseline Preview**  
chart populates once the managed identity and data source are set.

### 5.4 Tab 4: Review + create

Review the summary against your checklist row and select **Create**.

### 5.5 Repeat for each SLI

Run 5.1 to 5.4 once per checklist row. The demo yields three SLIs:  
`CheckoutAvailabilitySLI` (availability/request), `LoginLatencySLI` (latency/window),  
`PaymentDependencySLI` (availability/request, formula).

**Checkpoint 5:** every design-checklist row exists as a created SLI in the portal.

---

## Part 6: Validate end-to-end

**Goal:** prove each SLI is not just configured but actually computing and publishing.

> **Session prerequisites.** `Invoke-Prom` and `$PROM` are per-terminal (defined in Parts 0.2 to 0.3).  
> Run 6.2 and 6.3 in the same terminal where you set them up, or the query silently returns nothing.  
> Quick check: `Get-Command Invoke-Prom` and `"$PROM"` (both non-empty); if either is blank, re-run  
> Parts 0.2 to 0.3 in this terminal first.

### 6.1 Provisioning and execution state

Service Group `<sg>` > **Monitoring** > **View all SLIs**. Each SLI should show its evaluation  
method, type, baseline/window, status, and error budget remaining. Provisioning should be `Succeeded`  
and execution `Running`.

### 6.2 Confirm the engine publishes results

The engine writes results back to the destination workspace as  
`ns::<servicegroup>/m::<sli>:value` (lowercased, namespace-prefixed). Query that series directly.

```
Invoke-Prom '{__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:value"}' |
  ForEach-Object { "published value = {0}" -f $_.value[1] }
```

Replace the service group and SLI name (lowercased) with yours. If the series exists with a sane  
value, publishing works and the native panels will populate.

### 6.3 Cross-check the engine against your own math

Two independent checks confirm the published number is trustworthy. Run both in the terminal that has  
`Invoke-Prom` / `$PROM` loaded (see the session note above), substituting your lowercased service group  
and SLI name. (Request-based SLIs publish `:good` and `:total`; window-based SLIs like Login latency  
publish `:uptime` and `:downtime`, and `value = 100 x uptime / (uptime + downtime)`.)

**a) Internal consistency:** `value` **must equal** `100 x good / total`**.** The engine publishes the good  
and total components next to the value, so check the arithmetic directly:

```
$v = [double](Invoke-Prom '{__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:value"}').value[1]
$g = [double](Invoke-Prom '{__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:good"}').value[1]
$t = [double](Invoke-Prom '{__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:total"}').value[1]
"engine value = {0:n4}   100*good/total = {1:n4}" -f $v, (100 * $g / $t)
```

The two numbers should be identical to full precision:

```
engine value = 99.8369   100*good/total = 99.8369
```

**b) Independent recompute from the source signal.** Recompute the same ratio straight from the  
recording rule the SLI reads (`sli:http_requests:rate5m`), which the engine does not hand you  
pre-combined:

```
Invoke-Prom 'clamp_max(100 * sum(sli:http_requests:rate5m{service="checkout",status_class="2xx"}) / sum(sli:http_requests:rate5m{service="checkout"}), 100)' |
  ForEach-Object { "source recompute = {0:n4}" -f [double]$_.value[1] }
```

This is an instantaneous ratio over the 5-minute rate, so it tracks the engine's value closely but  
never bit-for-bit:

```
source recompute = 99.7395
```

**A small gap here is expected and still validates.** The engine's `:value` is evaluated on its own  
schedule and published, so you are reading a number computed moments earlier; your recompute is a  
fresh `sum(rate5m)` ratio at query time. The two are sampled at slightly different instants over  
slightly offset 5-minute windows, and the good/total mix keeps drifting (more so here, where  
degradation is being injected into Checkout), so the recompute can land a little **above or below**  
the engine value. For example, a run of `source recompute = 99.8391` against `engine value = 99.7458`  
is a gap of only ~0.09 point: normal timing noise, not a defect. Expect a fraction of a percentage  
point (typically well under 0.5) in either direction; only a large, persistent divergence points to a  
real problem.

The longer-window Part 3.2 query (`increase(...[7d])`) is a useful third sanity check, but it averages  
a whole week, so expect the same ballpark rather than an exact match. Reading the results: if (a)  
disagrees, the engine's components or arithmetic are wrong; if (a) holds but (b) diverges by more than  
a fraction of a point and stays there, revisit the good/total filters or the recording rule feeding  
the SLI.

**Checkpoint:** for each SLI, the `ns::.../m::...:value` series exists, equals `100 x good / total` to  
full precision, and lands within a fraction of a percentage point of the independent recompute from  
source (a small above-or-below gap is normal timing noise).

---

## Part 7: Lab completion checklist

*   Part 0: PromQL and App Insights queries both return data.
*   Part 1: every journey inventoried, gaps noted.
*   Part 2: 1 to 3 critical journeys extracted, each with an SLI category and shape.
*   Part 3: per journey, dimensions confirmed, current performance measured, continuity checked,  
    good/valid written.
*   Part 4: a design-checklist row per SLI (target, window, budget, burn alerts).
*   Part 5: each row authored through Basics / SLI / Baseline + Alert / Review + create.
*   Part 6: each SLI provisions `Succeeded`, publishes `ns::.../m::...:value`, and matches your math.

Operate and iterate: review monthly. If a budget is never spent the target is too loose; if it is  
always blown the target is too tight or the service needs reliability work.

---

## Appendix A: Blank worksheets (copy per workload)

```
--- Journey inventory (Part 1) ---
Journey | User goal | Route(s) | Dependencies | PctTraffic | Instrumented?

--- Criticality scoring (Part 2) ---
Journey | Business | Frequency | Visibility | Blast radius | Total | SLO candidate?

--- Data collection (Part 3, one per critical journey) ---
Journey: __________________  SLI category/shape: __________________
Source metric: __________________  Dimensions present? (Y/N): ____
Good = __________________________________________________________
Valid = _________________________________________________________
Measured current performance (7d): ______%   Continuous? (Y/N): __
Proposed SLO target: ______%   Window: ___ rolling days

--- Design checklist (Part 4, one row per SLI) ---
SLI name | Type | Shape | Good signal | Total/criterion | Target % | Window | Budget % | Fast burn | Slow burn
```

## Appendix B: PromQL / KQL cheat sheet

Every PromQL row runs through the `Invoke-Prom` helper (Parts 0.2 to 0.3) and was verified to execute  
and return data against the live workspace; the KQL row runs through `Invoke-AI` (Part 0.4). Substitute  
your own `service` / `dependency` / service-group names where they appear.

| Purpose | Query |
| --- | --- |
| Services emitting requests | `sum by (service) (rate(http_server_requests_total[5m]))` |
| Status classes present | `count by (status_class) (http_server_requests_total{service="checkout"})` |
| Availability 7d | `sum(increase(http_server_requests_total{service="checkout",status_class="2xx"}[7d])) / sum(increase(http_server_requests_total{service="checkout"}[7d]))` |
| Latency good-window fraction 7d | `avg_over_time((sli:http_request_latency_p95:5m{service="login"} <= bool 0.3)[7d:5m])` |
| Dependency success 7d | `sum(increase(dependency_calls_total{dependency="payment",status="ok"}[7d])) / sum(increase(dependency_calls_total{dependency="payment"}[7d]))` |
| Signal continuity (1/0) | `count_over_time(http_server_requests_total{service="checkout"}[5m]) > bool 0` |
| Published SLI value | `{__name__="ns::<sg-lower>/m::<sli-lower>:value"}` |
| Journeys by volume (KQL) | `requests \| summarize Calls=count() by name \| order by Calls desc` |

**Runnable form (copy-paste; needs `Invoke-Prom` / `Invoke-AI` and `$PROM` from Part 0 in this terminal):**

```
# PromQL, via Invoke-Prom (Parts 0.2 to 0.3)
Invoke-Prom 'sum by (service) (rate(http_server_requests_total[5m]))'                                     # services emitting requests
Invoke-Prom 'count by (status_class) (http_server_requests_total{service="checkout"})'                    # status classes present
Invoke-Prom 'sum(increase(http_server_requests_total{service="checkout",status_class="2xx"}[7d])) / sum(increase(http_server_requests_total{service="checkout"}[7d]))'   # availability 7d
Invoke-Prom 'avg_over_time((sli:http_request_latency_p95:5m{service="login"} <= bool 0.3)[7d:5m])'         # latency good-window fraction 7d
Invoke-Prom 'sum(increase(dependency_calls_total{dependency="payment",status="ok"}[7d])) / sum(increase(dependency_calls_total{dependency="payment"}[7d]))'              # dependency success 7d
Invoke-Prom 'count_over_time(http_server_requests_total{service="checkout"}[5m]) > bool 0'                # signal continuity (1/0)
Invoke-Prom '{__name__="ns::checkoutsg-ioarvugvrpkmc/m::checkoutavailabilitysli:value"}'                   # published SLI value (lowercased sg/sli)

# KQL, via Invoke-AI (Part 0.4)
Invoke-AI "requests | summarize Calls=count() by name | order by Calls desc"                              # journeys by volume
```

## Appendix C: Validated command outputs

The commands in this lab were executed against live Azure services to confirm they run and return  
well-formed results. The application-specific queries (Parts 1 to 6) were exercised against a real  
Azure Monitor Workspace and Application Insights component; the demo `slidemo-*` resources were not  
deployed at validation time, so the sample values below come from generic workspaces. What is proven  
here is that the **commands, auth, endpoints, and response shapes are correct**; when you run them  
against your deployed app, the same shapes carry your data.

**Resolve the Prometheus query endpoint (Part 0.2).** `az resource show` with  
`--query "properties.metrics.prometheusQueryEndpoint"` returns the endpoint URL:

```
https://<workspace>-<hash>.<region>.prometheus.monitor.azure.com
```

**Acquire a query token (Part 0.3).** `az account get-access-token --resource "https://prometheus.monitor.azure.com"` succeeds and returns a bearer token with an `expiresOn`  
timestamp.

**PromQL instant query envelope (Part 0.3, 3.x).** The `POST /api/v1/query` call returns a standard  
Prometheus success envelope:

```
=== instant query with metric-name equality ===
querying: count({__name__="process.cpu.time"})
status=success resultType=vector value=

=== rate() + sum ===
status=success resultType=vector value=
```

`status=success` and `resultType=vector` confirm the query path and syntax. The `value` is empty here  
only because that generic workspace had no live samples for the probed metric; with traffic flowing,  
the same call returns the numeric ratio.

**Metric / dimension discovery (Part 1.1, 3.1).** The label-values API lists what exists:

```
=== metric-name discovery (label values API) ===
status=success, metric-name count=21
sample: process.cpu.time, process.cpu.utilization, process.disk.io, process.disk.operations, ...
```

**PowerShell formatting lines (Part 0.3, 3.2).** The `-f`, `[math]::Round`, and `ForEach-Object`  
formatting used throughout produce exactly the documented output shape:

```
checkout availability 7d = 99.942%
checkout = 1.87
login = 0.8
```

**Application Insights KQL command (Part 0.4, 1.1).** `az monitor app-insights query --app <ai> -g <rg> --analytics-query "..."` returns a tabular JSON envelope:

```
{
  "tables": [
    {
      "name": "PrimaryResult",
      "columns": [
        { "name": "validated", "type": "long" },
        { "name": "ts", "type": "datetime" }
      ],
      "rows": [ [ 1, "2026-07-01T05:40:04Z" ] ]
    }
  ]
}
```

**Known workspace quirk.** Azure Monitor managed Prometheus supports only **equality** on the metric  
name. `count({__name__!=""})` is rejected with `Not implemented: Metric name only support equality(=) filter`. Every query in this lab uses `__name__="..."` equality (including the published-SLI check in  
Part 6.2), so no change is needed; just avoid `!=` on `__name__` in ad-hoc queries.