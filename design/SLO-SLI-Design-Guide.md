# SLO / SLI Design: Foundations and Process

A single, ground-up guide to defining SLOs and SLIs for any workload. It starts at zero, builds each
idea on the one before it, states the design requirements the theory forces, then turns those into a
repeatable, vendor-neutral process with the concrete Azure implementation (Azure Monitor Service
Groups + Azure Monitor Workspace (AMW) + Prometheus recording rules). The worked example throughout is
the Checkout Service Group demo (`CheckoutSG-ioarvugvrpkmc`).

Read order matters: think **SLO-first** (define the target), then design the **SLI (the measurement)**
that proves whether you are meeting it. In the Azure form you enter them in the reverse order (SLI
signals first, SLO baseline last), but you should *think* SLO-first.

For the executable, command-by-command version of this process, see
[SLO-SLI-Design-Lab.md](SLO-SLI-Design-Lab.md).

> This document is the single source of truth for SLO/SLI design theory and process. Sections 1 to 6
> are the first-principles theory; sections 7 onward are the practice (demo specifics, the reusable
> process, Azure form mapping, gotchas, and worksheets).

---

## 1. Why any of this exists

Every service makes an implicit promise to its users: "I will be here, and I will work." The problem
is that "work" and "be here" are fuzzy. Two honest engineers can look at the same system and disagree
about whether it is healthy. Users, meanwhile, do not care about CPU graphs. They care about whether
their checkout went through.

The purpose of SLIs and SLOs is to replace arguments and gut feelings with **one agreed number and
one agreed target**. Once you have those, questions that used to be endless debates become arithmetic:

- Is the service healthy right now? Compare the number to the target.
- Can we ship a risky change this week? Check how much of the budget is left.
- Should we invest in reliability or in features? Look at whether the budget is chronically empty or
  chronically full.

Everything below builds toward being able to answer those three questions with data.

---

## 2. The layered mental model

Each layer depends on the one before it. Do not skip ahead.

```
Layer 1  User experience        "Did the customer have a good time?"
Layer 2  Event                  One measurable thing the user did (a request, a payment)
Layer 3  Good vs valid          A rule that labels each event good or not
Layer 4  SLI                    good events / valid events, as a percentage
Layer 5  SLO                    SLI + target + time window
Layer 6  Error budget           1 - SLO: how much failure is allowed
Layer 7  Burn rate              How fast you are spending the budget
Layer 8  Alerting               Page a human when burn rate is dangerous
```

The rest of this section walks up the ladder one rung at a time.

### Layer 1: Start with the user, not the machine

Pick the thing the user is trying to accomplish. Not a server, not a database, not a queue. A user
goal. "Log in." "Check out." "See my balance." This is called the **critical user journey**. If you
find yourself describing infrastructure, you have gone too deep; climb back up until you are
describing something a customer would recognize.

### Layer 2: Turn the goal into events

A goal you cannot count is a goal you cannot measure. So express the journey as a stream of
**events**: discrete things that happen and that you can, in principle, tally. A checkout is a stream
of HTTP requests. A payment is a stream of dependency calls. Each event either helped the user or did not.

### Layer 3: Define good vs valid (the most important step)

For each event you need two rules, written in plain language before you touch any tool:

- **Valid**: which events count at all? (Usually "all real checkout requests," excluding health
  checks and synthetic probes.)
- **Good**: among the valid ones, which made the user happy? (Usually "returned HTTP 2xx" or "served
  in under 300 ms.")

Almost every measurement mistake traces back to a sloppy definition here. Be ruthless: is a 3xx
redirect good? Is a 404 the user's fault or yours? Do slow-but-successful requests count as good? Write
the answers down as sentences. If you cannot write the sentence, you cannot build the SLI.

### Layer 4: The SLI is just a ratio

Once good and valid are defined, the **Service Level Indicator** is trivial:

$$
\text{SLI} = \frac{\text{good events}}{\text{valid events}} \times 100\%
$$

That is the whole definition. An SLI is a percentage that says "this fraction of the time, the user
had a good experience." It is the speedometer: it tells you your current speed and nothing more.

### Layer 5: The SLO adds a target and a window

An SLI alone is just a reading. To make it a promise you add two things:

- A **target**: the SLI must stay at or above, say, 99.9%.
- A **window**: measured over the last 7 rolling days (not a calendar month, so the number never
  resets abruptly).

$$
\text{SLO} = \text{SLI} + \text{target} + \text{window}
$$

The **Service Level Objective** is the speed limit. "99.9% of checkout requests succeed, measured over
7 rolling days" is a complete SLO. Note the discipline: a target without a window is meaningless (99.9% over what?), and a window without a target is just a chart.

### Layer 6: The error budget is the target inverted

If you promise 99.9% success, you have simultaneously admitted that **0.1% may fail**. That allowance
is the **error budget**:

$$
\text{error budget} = 1 - \text{SLO}
$$

This reframing is the single most useful idea in the whole discipline. Failure is no longer a
catastrophe to be driven to zero; it is a **budget to be spent wisely**. You can spend it on risky
deploys, on experiments, on maintenance. As long as you stay within budget, you are keeping your
promise. The budget turns reliability from a moral argument into an accounting problem.

### Layer 7: Burn rate is the speed of spending

Two outages can consume the same total budget: one small leak over a week, one sharp break in an hour.
You care far more about the sharp break. **Burn rate** captures this by measuring how fast you are
consuming budget relative to "sustainable":

- **1x** burn = spending the budget exactly as fast as the window allows. You will end the window at
  precisely 0 budget. On track.
- **14.4x** burn = spending 14.4 times too fast. At this rate a multi-day budget is gone in hours.
- **45x** burn = an emergency; the budget evaporates almost immediately.

Burn rate is what makes a "small" dip visible as the large problem it may actually be. A service
dropping from 100% to 95% success sounds mild, but against a 0.1% budget that is roughly a 45x burn:
the entire week's allowance gone in minutes.

### Layer 8: Alert on burn rate, not on the raw number

The final rung. Do not page a human because availability touched 99.8% for one minute; that may be
well within budget. Page them because the **budget is draining dangerously fast**. Typical practice
uses two alerts:

- **Fast burn** (for example 14.4x over 1 hour): wake someone up, this is a page.
- **Slow burn** (for example 1x over 6 hours): file a ticket, look at it during the day.

This way the severity of the alert matches the severity to the user, not the size of the raw number.

---

## 3. Worked example: walking the ladder for a checkout

To make the layers concrete, here is the same climb applied to one real journey step.

| Layer           | Applied to checkout                                     |
| --------------- | ------------------------------------------------------- |
| 1. User goal    | A customer completes a purchase                         |
| 2. Events       | Each HTTP request to the checkout service               |
| 3. Good / valid | Valid = all checkout requests; Good = returned HTTP 2xx |
| 4. SLI          | 2xx checkout requests / all checkout requests           |
| 5. SLO          | 99.9% over 7 rolling days                               |
| 6. Error budget | 0.1% of checkout requests may fail                      |
| 7. Burn rate    | A drop to 95% success is roughly 45x burn               |
| 8. Alert        | Fast: 14.4x over 1h (page). Slow: 1x over 6h (ticket)   |

Read top to bottom, each row is forced by the row above it. That is the point: once you commit to the
user goal and the good/valid rule, everything else is derived, not invented.

---

## 4. Two shapes of SLI you will meet

Most SLIs come in one of two shapes. Knowing which you are building changes how you define "good."

### 4a. Request-based (count the good events)

You literally count good events and valid events and divide. Best for **availability** ("did it
succeed?"). Good = 2xx, valid = all requests. This is the intuitive shape and covers most services.

### 4b. Window-based (count the good time slices)

Sometimes you cannot label individual events cleanly, especially for **latency**. You cannot say a
single request "is P95"; a percentile only exists across many requests. So instead you chop time into small windows (say 5 minutes), and label each **window** good or bad:

- A window is **good** if its P95 latency was at or below the threshold (for example 300 ms).
- SLI = good windows / total windows.

The consequence is important: a sustained latency breach turns whole windows bad at once, so the SLI falls fast toward 0%, not in tiny increments. Latency problems look and feel different from
availability problems in the numbers, and this is why.

---

## 5. Vocabulary quick reference

The layers above, condensed into a lookup table with this demo's examples. Pin this when filling in a
portal form.

| Term | One-line definition | This demo's example |
|---|---|---|
| **SLI** (indicator) | A number that measures one dimension of customer experience, usually a ratio of *good events / valid events*. | Checkout success rate = 2xx checkout requests / all checkout requests |
| **SLO** (objective) | The target the SLI must meet over a window. SLI + target + window. | 99.9% over 7 rolling days |
| **Error budget** | The allowed amount of failure = `1 - SLO`. | 0.1% of checkout requests may fail |
| **Burn rate** | How fast you are consuming the error budget, in multiples of "sustainable". | 1x = exactly on budget; 45x = budget gone fast |
| **Evaluation window** | The rolling period the SLO is judged over. | 7 rolling days |

Mental model: **SLI = the speedometer. SLO = the speed limit. Error budget = how far over the
limit you can drive before you get a ticket. Burn rate = how fast you are using that allowance.**

---

## 6. From theory to design requirements

Everything above is vendor-neutral theory. Now we state what the theory **requires** of any real
implementation. These are the design requirements: if you violate them, the numbers will be wrong or absent, no matter how good your intentions.

### Requirement 1: Pick the journey, not the endpoint

You must choose 1 to 3 user journey steps plus their critical dependencies. You must **not** create an
SLO per endpoint. An SLO for every route produces noise no one reads and budgets no one defends. The design requirement is deliberate scarcity: few SLOs, each defending something a customer cares about.

### Requirement 2: Define good and valid in writing before building

Each SLI must have its good and valid rules written as plain sentences, including the edge cases:
which status codes count, which traffic is excluded (health checks, synthetics), whether slow
successes count. This document is the contract. Building queries before writing sentences is the
most common and most expensive mistake.

### Requirement 3: Targets must be measured, not aspirational

The SLO target must start from **current observed performance**, not from a default of "five nines."
A target you cannot meet trains everyone to ignore the budget; a target you never stress is not
protecting anything. Set tighter targets on more critical steps (checkout tighter than a dependency)
and looser on the rest. Every target needs a rolling window attached.

### Requirement 4: The metric must carry the right dimensions

This is the requirement most implementations get wrong, so it deserves the most care. An SLI engine
can only split good from valid using **labels (dimensions) that physically exist on the metric it
reads**. Therefore:

- The application must emit counters and histograms tagged with the labels the SLI needs to filter on, for example `http_server_requests_total{service, status_class, route}` and
  `dependency_calls_total{dependency, status}`, plus a latency histogram for P95.
- If the SLI engine reads from a metrics store with **recording rules**, those rules must pre-aggregate to exactly the labels the SLI filters on. The engine sees labels on the recording-rule output, not on the raw underlying series.
- **Every** sample must carry those dimensions. A single series missing `service` or `status_class`
  silently breaks the good/valid matching.

If the dimension does not exist on the metric, no amount of portal configuration can recover it. Design the instrumentation and the SLI definition together, never separately.

### Requirement 5: The source metric must never go silent

An SLI is only as alive as its input. If traffic stops, the source metric goes empty, the evaluation window fills with NaN, and the engine publishes nothing at all: the panel reads "No data" even though every setting is perfect. The design requirement is a **continuous signal**: keep real or synthetic traffic flowing so every evaluation window has samples. A heartbeat of load is part of the design, not an afterthought.

### Requirement 6: Plan the burn-rate alerts as part of the design

Alerting is not bolted on later. Each SLO must ship with its burn-rate alert policy defined up front: a fast-burn page and a slow-burn ticket, with explicit multipliers and windows. The alert thresholds are derived from the error budget, so they belong in the same design conversation as the target.

### Requirement 7: Validate that the engine actually publishes

A configured SLI is not a working SLI. The design must include a validation step that confirms the
engine writes its output back (its Value, Good, and Total series) to the destination store, and that those numbers agree with an independent hand computation from the same source metrics. Trust the published series, not the portal's optimism.

---

## 7. How this demo defines its SLOs (SLO-first view)

Three SLOs were chosen because they map to the **critical user journey** (a customer logging in and
checking out) and its **key dependency** (payment).

| Service / journey step | SLO target | Window | SLI category |
|---|---|---|---|
| Checkout availability | **99.9%** success | 7 rolling days | Availability (request-based) |
| Login latency | **99%** of windows with **P95 <= 300 ms** | 7 rolling days | Latency (window-based) |
| Payment dependency | **99.5%** success | 7 rolling days | Availability (request-based) |

Note the deliberate variety:
- Two **request-based availability** SLOs (good requests / total requests).
- One **window-based latency** SLO (count a 5-minute window as good if P95 <= threshold, then target
  a percentage of good windows).
- Tighter target (99.9%) on the most critical step (checkout), looser (99.5%) on the dependency.

---

## 8. How each SLI is specified (SLI-second view)

Every SLI is a **good signal** and a **total signal** (request-based) or a **window uptime criterion**
(window-based), expressed over a metric with the right dimensions.

### 8a. Checkout Availability (request-based)
- Good signal: `sli:http_requests:rate5m` filtered `service = checkout` AND `status_class = 2xx`
- Total signal: `sli:http_requests:rate5m` filtered `service = checkout`
- SLI value = Good / Total. Target 99.9%.

### 8b. Payment Dependency (request-based)
- Good signal: `sli:dependency_calls:rate5m` filtered `dependency = payment` AND `status = ok`
- Total signal: `sli:dependency_calls:rate5m` filtered `dependency = payment`
- SLI value = Good / Total. Target 99.5%.

### 8c. Login Latency (window-based)
- Signal: `sli:http_request_latency_p95:5m` filtered `service = login`
- Window uptime criterion: window is **good** when value `<= 0.3` (300 ms), evaluated per 5-minute window.
- SLI value = good windows / total windows. Target 99%.

---

## 9. The reusable design process (apply to any new workload)

Follow these steps in order; they operationalize the requirements in section 6. Steps 1-6 are
vendor-neutral SRE design. Steps 7-9 are the Azure implementation.

### Step 1 - Identify the critical user journey
Ask: *what does the customer actually do, and what would make them unhappy?* Pick the 1-3 steps that
matter most (here: log in, check out) plus critical dependencies (payment). Do **not** make an SLO for
every endpoint; pick the journey.

### Step 2 - Choose the SLI category per step
For each step pick the dimension of experience that best reflects pain:
- **Availability** (did the request succeed?) - default for most request/response services.
- **Latency** (was it fast enough?) - for steps where slowness is the failure mode.
- **Throughput / correctness / freshness / coverage** - rarer, use when relevant.
A single step can have more than one SLI (e.g., checkout could have both availability and latency).

### Step 3 - Write the SLI specification (good vs valid events)
Define in plain language **before** any query:
- **Availability:** good = "HTTP 2xx", valid = "all requests to this service". SLI = good/valid.
- **Latency:** good = "request served in <= X ms", valid = "all requests"; OR window form: a window is
  good if P95/P99 <= threshold.
Be explicit about what counts: which status codes are "good" (2xx? also 3xx? exclude 4xx client
errors?), which requests are "valid" (exclude health checks, synthetic traffic, etc.).

### Step 4 - Set the SLO target and window
- Pick a target that is **achievable and meaningful**, not aspirational. Start from current measured
  performance, not "five nines by default".
- Tighter targets for more critical steps. (Demo: checkout 99.9% > payment 99.5%.)
- Pick a **rolling window** (7, 28, or 30 days are typical). Rolling is preferred over calendar so the
  budget does not reset abruptly. (Demo: 7 rolling days.)
- The error budget falls out automatically: `budget = 1 - SLO` (99.9% -> 0.1%).

### Step 5 - Decide the alerting strategy (burn rate)
Alert on **error-budget burn rate**, not raw availability, so a tiny dip that is catastrophic relative
to a tight budget pages you, while a large-but-affordable blip does not. Typical multi-window burn-rate
alerts: fast burn (e.g., 14.4x over 1h) for pages, slow burn (e.g., 1x over 6h) for tickets.

### Step 6 - Instrument the source metric with the right dimensions
This is the step most setups get wrong. The SLI engine can only filter on **dimensions (labels) that
exist on the metric it reads**. So:
- Emit a counter/histogram from the app with labels that let you split good vs total:
  - `http_server_requests_total{service, status_class, route, ...}`
  - `dependency_calls_total{dependency, status}`
  - a latency histogram for P95 (`http_server_request_duration_seconds_bucket{...}`)
- If the engine reads from an AMW, expose **recording rules** that pre-aggregate to exactly the
  dimensions the SLI filters on. The query engine sees labels on *recording-rule output*, not on raw
  remote-written series. (Demo rules: `sli:http_requests:rate5m{service,status_class}`,
  `sli:dependency_calls:rate5m{dependency,status}`, `sli:http_request_latency_p95:5m{service}`.)
- Verify **every** sample carries the dimensions you filter on (no series missing `service` or
  `status_class`). A missing dimension breaks good/total matching.

### Step 7 - Author the SLI in Azure (map design -> form fields)
On the Service Group, create the SLI. The "Edit SLI" form maps to the design like this:

| Form field | What to enter | From which design step |
|---|---|---|
| Service Group | The Service Group that scopes this workload | Step 1 |
| SLI type | Availability or Latency | Step 2 |
| SLI name / description | Human-readable name + the spec sentence | Step 3 |
| Evaluation method | "Request Count Based" (request-based) or window-based | Step 2/3 |
| Managed Identity | The user-assigned identity that can read the AMW | Step 7 prereqs |
| Data source | The source AMW holding the metrics | Step 6 |
| Good signal(s) | Metric + filters (e.g., `service eq checkout`, `status_class eq 2xx`) + Summarize Sum by dimensions | Step 3 |
| Total signal(s) | Same metric + the broader filter (e.g., `service eq checkout`) | Step 3 |
| Window uptime criterion (latency) | Comparator + threshold (e.g., `<= 0.3`) and window size (5 min) | Step 3 |
| Baseline (SLO) | The target number (e.g., 99.9) | Step 4 |
| Evaluation period | Rolling days (e.g., 7 rolling) | Step 4 |
| Identity + Storage location | Identity + destination AMW where SLI results are published | Step 7 prereqs |
| Alerts | Enable + burn-rate alert rules | Step 5 |

**Prerequisites the form assumes are already done:**
- A **user-assigned managed identity** with, on the AMW: `Monitoring Reader`, `Monitoring Data Reader`
  (read source) and `Monitoring Metrics Publisher` (publish results), plus `Monitoring Metrics
  Publisher` on the AMW's data collection rule.
- The Service Group exists and has **monitoring settings** pointing at the default AMW + identity.
- Source metric **dimensions are indexed** in the AMW metric-metadata store (the SLI validator rejects
  dimension filters until indexing completes).

### Step 8 - Validate end-to-end
- Confirm the SLI provisions `Succeeded` and `executionState: Running`.
- Confirm it **publishes** output. The engine writes back `<SLI>:Value/Good/Total` to the destination
  AMW. In Prometheus these surface as `ns::<servicegroup>/m::<sli>:value` (lowercased,
  namespace-prefixed). If those series exist with sane values, the portal "Manage SLIs" status and
  native panels will populate.
- Cross-check the engine's number against your own computation from the same recording rules (a
  workbook is ideal for this). They should agree.

### Step 9 - Operate and iterate
- Build a dashboard (Workbook/Grafana) with, per SLI: **Metric** (SLI %), **Error Budget Remaining**,
  **Burn Rate**, plus the SLO target line and a 1x burn line for context.
- Review monthly: if you never spend budget, the SLO is too loose; if you always blow it, it is too
  tight or the service needs reliability work. Adjust target or invest.

---

## 10. Lessons learned (gotchas that cost real debugging time)

1. **Dimensions live on recording-rule output, not raw series.** Build recording rules that emit
   exactly the labels your SLI filters on, and confirm every sample has them.
2. **The source metric must be continuous.** If the app stops receiving traffic, the source metric
   goes empty, the SLI evaluation window is all-NaN, and the engine publishes nothing
   (`NoContent`) - the native panel shows "No data" even though config is perfect. Keep a steady
   traffic/heartbeat so evaluation windows always have data.
3. **A dashboard can lie about gaps.** Wide `increase()`/`avg_over_time()` windows carry the last
   value across gaps and make missing data look present. Add a raw, un-masked "source data present
   (1/0)" panel to tell the truth about continuity.
4. **Know where the engine publishes.** Output lands in the **destination AMW** as
   `ns::<servicegroup>/m::<sli>:value` (lowercased, namespace-prefixed). Query that exact name to
   verify publish independently of the portal.
5. **A small SLI dip can be a huge SLO breach.** With a 0.1% budget, a metric "only" dropping to 95%
   is a ~45x burn and exhausts the budget immediately. Always pair the SLI % with error budget +
   burn rate so the severity is visible.
6. **RBAC needs both read and publish.** The identity must read the source AMW *and* publish to the
   destination AMW (`Monitoring Metrics Publisher` on the AMW and its DCR).
7. **Latency SLIs are window-based.** "P95 <= 300 ms" is judged per window; the SLI value is the
   fraction of good windows, so a sustained latency breach drives it toward 0% (not a small dip).

---

## 11. Worksheet for a new workload (copy and fill in)

```
Workload / service: ____________________________
Critical user journey step: _____________________

SLI #1
  Category (availability / latency / ...): ______
  Request-based or window-based: ________________
  Good events  = ________________________________
  Valid events = ________________________________
  Source metric + dimensions = __________________
  SLO target = ______%   Window = ____ rolling days
  Error budget = 1 - target = ______%
  Burn-rate alert(s): fast ____x/__h, slow ____x/__h

SLI #2 (dependency or latency)
  ... repeat ...
```

Worked example (this demo):
```
Workload: Checkout Service Group
Step: Checkout

SLI: Checkout Availability
  Category: Availability (request-based)
  Good events  = http 2xx checkout requests
  Valid events = all checkout requests
  Source metric = sli:http_requests:rate5m{service,status_class}
  SLO target = 99.9%   Window = 7 rolling days
  Error budget = 0.1%
  Burn-rate alert: fast 14.4x/1h (page), slow 1x/6h (ticket)
```

---

## 12. Summary

Start with the user, not the machine. Turn their goal into countable events, then write down which
events are valid and which are good. The ratio of good to valid is your **SLI**; add a target and a
rolling window and it becomes an **SLO**; one minus the target is your **error budget**; how fast you
spend it is the **burn rate**; and you alert on burn rate, not on raw numbers. The design requirements
all follow from this chain: pick few journeys, define good and valid in writing, set measured targets,
instrument the metric with the exact dimensions the SLI needs, keep the signal continuous, plan the
burn-rate alerts up front, and validate that the engine truly publishes. Get the chain right and
reliability stops being an argument and becomes arithmetic.

The process in nine steps: 1. Pick the journey. 2. Pick the SLI category. 3. Write good/valid events.
4. Set SLO target + rolling window (budget = 1 - target). 5. Plan burn-rate alerts. 6. Instrument the
metric with the exact dimensions. 7. Author the SLI (map design -> form). 8. Validate the engine
**publishes** `ns::<sg>/m::<sli>:value`. 9. Dashboard it and review monthly.

Define the **SLO** (what "good enough" means) before the **SLI** (how you measure it); implement the
SLI signals first in the tooling, with the SLO target as the baseline.
