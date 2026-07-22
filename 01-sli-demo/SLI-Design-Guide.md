# SLO / SLI Design: Foundations and Process

A complete, beginner-friendly guide to defining SLOs and SLIs for any workload. It starts from the basics and adds one idea at a time: first the theory, then the design rules that follow from it, then a simple step-by-step process you can reuse with any tool. Every idea is shown with a concrete Azure setup (Azure Monitor Service Groups, an Azure Monitor Workspace (AMW), and Prometheus recording rules). The running example is the Checkout Service Group demo (`CheckoutSG-ioarvugvrpkmc`).

Order of thinking matters: decide the **SLO first** (the target you want to hit), then design the **SLI** (the measurement that tells you whether you are hitting it). The Azure form asks for them in the opposite order (SLI signals first, SLO baseline last), but you should still _think_ SLO first.

For the step-by-step, command-by-command version of this process, see [SLI-Lab-UserGuide.md](SLI-Lab-UserGuide.md).

> This document is the main reference for SLO/SLI design theory and process. Sections 1 to 4 cover the theory from first principles; sections 5 onward cover the practice (the demo's SLIs, the design rules and the lab phase that carries out each one, gotchas, and a worksheet).

## Contents

1.  [Why any of this exists](#1-why-any-of-this-exists)
2.  [The layered mental model](#2-the-layered-mental-model)
3.  [Two shapes of SLI you will meet](#3-two-shapes-of-sli-you-will-meet)
4.  [Vocabulary quick reference](#4-vocabulary-quick-reference)
5.  [The demo's three SLIs](#5-the-demos-three-slis)
6.  [Design rules and the process](#6-design-rules-and-the-process)
7.  [Gotchas that cost real debugging time](#7-gotchas-that-cost-real-debugging-time)
8.  [Worksheet and recap](#8-worksheet-and-recap)
9.  [Reliability talking points for the customer](#9-reliability-talking-points-for-the-customer)
10.  [Mapping the demo to Azure Monitor SLI features](#10-mapping-the-demo-to-azure-monitor-sli-features)

---

## 1\. Why any of this exists

Every service makes an unspoken promise to its users: it will be available, and it will work correctly. The trouble is that "available" and "works" mean different things to different people. Two honest engineers can look at the same system and disagree about whether it is healthy. Users do not care about CPU graphs; they only care whether their checkout went through.

SLIs and SLOs replace those arguments and gut feelings with **one agreed number and one agreed target**. Once you have both, questions that used to be endless debates turn into simple math:

*   Is the service healthy right now? Compare the number to the target.
*   Can we ship a risky change this week? Check how much of the budget is left.
*   Should we invest in reliability or in new features? See whether the budget is usually empty or usually full.

Everything below builds toward answering those three questions with data instead of opinions.

---

## 2\. The layered mental model

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

Pick the thing the user is trying to accomplish. Not a server, not a database, not a queue. A user goal. "Log in." "Check out." "See my balance." This is called the **critical user journey**. If you find yourself describing infrastructure, you have gone too deep; climb back up until you are describing something a customer would recognize.

### Layer 2: Turn the goal into events

A goal you cannot count is a goal you cannot measure. So express the journey as a stream of **events**: discrete things that happen and that you can, in principle, tally. A checkout is a stream of HTTP requests. A payment is a stream of dependency calls. Each event either helped the user or did not.

### Layer 3: Define good vs valid (the most important step)

For each event you need two rules, written in plain language before you touch any tool:

*   **Valid**: which events count at all? (Usually "all real checkout requests," excluding health checks and synthetic probes.)
*   **Good**: among the valid ones, which made the user happy? (Usually "returned HTTP 2xx" or "served in under 300 ms.")

Almost every measurement mistake comes from a sloppy definition here. Be strict: is a 3xx redirect good? Is a 404 the user's fault or yours? Do slow-but-successful requests count as good? Write the answers down as sentences. If you cannot write the sentence, you cannot build the SLI.

### Layer 4: The SLI is just a ratio

Once good and valid are defined, the **Service Level Indicator** is simple:

**SLI = (good events / valid events) × 100%**

That is the whole definition. An SLI is a percentage that says "this fraction of the time, the user had a good experience." It is simply a reading of how the service is doing right now, nothing more.

### Layer 5: The SLO adds a target and a window

An SLI alone is just a reading. To make it a promise you add two things:

*   A **target**: the SLI must stay at or above, say, 99.5%.
*   A **window**: measured over the last 7 rolling days (not a calendar month, so the number never resets abruptly).

**SLO = SLI + target + window**

The **Service Level Objective** is the speed limit. "99.5% of checkout requests succeed, measured over 7 rolling days" is a complete SLO. Notice the rule: a target without a window means nothing (99.5% over what?), and a window without a target is just a chart.

### Layer 6: The error budget is the target inverted

If you promise 99.5% success, you have simultaneously admitted that **0.5% may fail**. That allowance is the **error budget**:

**error budget = 1 - SLO**

This is the single most useful idea in the whole practice. Failure is no longer a catastrophe to drive to zero; it is a **budget to spend wisely**. You can spend it on risky deploys, on experiments, on maintenance. As long as you stay within budget, you are keeping your promise. The budget turns reliability from an opinion into an accounting problem.

### Layer 7: Burn rate is the speed of spending

Two outages can consume the same total budget: one small leak over a week, one sharp break in an hour. You care far more about the sharp break. **Burn rate** captures this by measuring how fast you are consuming budget relative to "sustainable":

*   **1x** burn = spending the budget exactly as fast as the window allows. You will end the window at precisely 0 budget. On track.
*   **14.4x** burn = spending 14.4 times too fast. At this rate a multi-day budget is gone in hours.
*   **45x** burn = an emergency; the budget evaporates almost immediately.

Burn rate is what makes a "small" dip visible as the large problem it may actually be. A service dropping from 100% to 95% success sounds mild, but against a 0.5% budget that is roughly a 10x burn: the entire week's allowance gone within a day.

### Layer 8: Alert on burn rate, not on the raw number

The final rung. Do not page a human because availability touched 99.8% for one minute; that may be well within budget. Page them because the **budget is draining dangerously fast**. Typical practice uses two alerts:

*   **Fast burn** (for example 14.4x over 1 hour): wake someone up, this is a page.
*   **Slow burn** (for example 1x over 6 hours): file a ticket, look at it during the day.

This way the severity of the alert matches the severity to the user, not the size of the raw number.

### The whole ladder for one checkout

The same climb applied to one real journey step:

| Layer | Applied to checkout |
| --- | --- |
| 1\. User goal | A customer completes a purchase |
| 2\. Events | Each HTTP request to the checkout service |
| 3\. Good / valid | Valid = all checkout requests; Good = returned HTTP 2xx |
| 4\. SLI | 2xx checkout requests / all checkout requests |
| 5\. SLO | 99.5% over 7 rolling days |
| 6\. Error budget | 0.5% of checkout requests may fail |
| 7\. Burn rate | A drop to 95% success is roughly 10x burn |
| 8\. Alert | Fast: 14.4x over 1h (page). Slow: 1x over 6h (ticket) |

Read top to bottom: each row follows from the one above it. That is the point: once you fix the user goal and the good/valid rule, everything else is derived, not invented.

---

## 3\. Two shapes of SLI you will meet

Most SLIs come in one of two shapes. Knowing which you are building changes how you define "good."

### 4a. Request-based (count the good events)

You literally count good events and valid events and divide. Best for **availability** ("did it succeed?"). Good = 2xx, valid = all requests. This is the intuitive shape and covers most services.

### 4b. Window-based (count the good time slices)

Sometimes you cannot cleanly label a single event, especially for **latency**. One request cannot "be P95"; a percentile only exists across many requests. So instead you split time into small windows (say 5 minutes) and mark each **window** good or bad:

*   A window is **good** if its P95 latency was at or below the threshold (for example 300 ms).
*   SLI = good windows / total windows.

Here is why this matters: a long latency problem turns whole windows bad all at once, so the SLI drops fast toward 0%, not in small steps. That is why latency problems look different from availability problems in the numbers.

> **This demo implements its latency SLI in the request-based shape instead** (proportion of login requests under 300 ms: good = requests at or under the threshold, total = all requests). It reads the counter recording rules `sli:http_request_latency_good:rate5m` / `sli:http_request_latency_total:rate5m`, which register reliably and never go `NaN`. Window-based remains the right tool when you genuinely cannot label individual events.

### 4c. Fast requests vs good windows: which to use when

Both shapes answer the same latency question ("was it fast enough?"), but they count different things and can give very different scores for the same incident.

**The plain-language version.** Picture a help desk that promises to answer every call quickly.

*   **Request-based (fast requests / total)** counts _every call_. Each call is answered quickly or slowly, and your score is quick answers divided by all calls. A bad rush hour where 200 calls are answered slowly puts 200 black marks on the board, because 200 real customers were left waiting.
*   **Window-based (good windows / total)** counts _bad hours_, not calls. Every hour you ask one yes/no question ("was this hour good overall?"). That same rush hour is just **one** bad hour, whether 5 or 500 calls were slow inside it.

Same problem, two different scores: request-based measures the **size** of the problem (how many customers were hurt), window-based measures the **duration** of the problem (how long you were struggling).

**How each is computed.**

*   **Request-based SLI** = requests faster than the threshold / all valid requests
*   **Window-based SLI** = good time windows / all time windows

**Which to use.**

**Request-based** when you have steady, high-volume per-request latency data and care about the _proportion of users_ who were slow. This is the default for user-facing services, and what this demo uses.

**Window-based** when you only have pre-aggregated percentiles (e.g., a P95 gauge per minute), the thing is inherently time-based (a batch job or poller), or traffic is so low that one request should not swing the score.

**Rule of thumb.** "Did it succeed?" (availability) is almost always request-based. "Was it fast enough?" (latency) is request-based when you have the per-request distribution, and window-based when you only have pre-aggregated percentiles.

---

## 4\. Vocabulary quick reference

The layers above, condensed into a lookup table with this demo's examples. Pin this when filling in a portal form.

| Term | One-line definition | This demo's example |
| --- | --- | --- |
| **SLI** (indicator) | A number that measures one dimension of customer experience, usually a ratio of _good events / valid events_. | Checkout success rate = 2xx checkout requests / all checkout requests |
| **SLO** (objective) | The target the SLI must meet over a window. SLI + target + window. | 99.5% over 7 rolling days |
| **Error budget** | The allowed amount of failure = `1 - SLO`. | 0.5% of checkout requests may fail |
| **Burn rate** | How fast you are consuming the error budget, in multiples of "sustainable". | 1x = exactly on budget; 45x = budget gone fast |
| **Evaluation window** | The rolling period the SLO is judged over. | 7 rolling days |

---

## 5\. The demo SLIs

Three SLOs map to the **critical user journey** (logging in and checking out) and its **key dependency** (payment). Each is request-based, with value = Good / Total, and each targets **99.5%** over a 7-rolling-day window. You can set tighter targets on more critical steps (for example checkout > dependency) when measured performance supports it.

| SLI | Category | Good signal | Total signal |
| --- | --- | --- | --- |
| Checkout Availability | Availability | `sli:http_requests:rate5m` where `service = checkout` AND `status_class = 2xx` | `sli:http_requests:rate5m` where `service = checkout` |
| Payment Dependency | Availability | `sli:dependency_calls:rate5m` where `dependency = payment` AND `status = ok` | `sli:dependency_calls:rate5m` where `dependency = payment` |
| Login Latency | Latency | `sli:http_request_latency_good:rate5m` where `service = login` (requests under 300 ms, from the histogram bucket at `le="0.3"`) | `sli:http_request_latency_total:rate5m` where `service = login` |

Login is modeled request-based (proportion of login requests under 300 ms) rather than window-based, because the counter signals register reliably and never go `NaN`.

### Alternative ingestion: AKS + Managed Prometheus

The SLI design does not depend on how metrics reach the Azure Monitor Workspace. This demo emits OpenTelemetry from App Services and forwards it with an OpenTelemetry Collector over Prometheus remote write. If you prefer the most common SLI metric path, containerize the apps and run them on **AKS with Managed Prometheus**: the apps expose `/metrics`, Managed Prometheus scrapes them into the AMW, and SLI authoring is identical. Only the ingestion path changes; the recording rules, good/total signals, and baselines stay the same.

---

## 6\. Design rules and the process

The theory forces a handful of design rules. Each is a principle you apply once; the executable, command-by-command version of every step lives in the lab's Path B ([SLI-Lab-UserGuide.md](SLI-Lab-UserGuide.md)). This section states the rules and points to the phase that carries each one out, rather than repeating the commands. Rules 1-6 are tool-independent SRE design; rules 7-9 are the Azure implementation.

| # | Design rule | What it enforces | Executed in (lab Path B) |
| --- | --- | --- | --- |
| 1 | **Base SLOs on user journeys, not individual endpoints** | An SLO measures a complete user goal (log in, check out), not a single API route; keep them few (one per critical journey plus its key dependencies) so each protects something customers actually notice | Phase 2-3 (enumerate journeys, extract the critical 1-3) |
| 2 | **Match each SLI to the kind of failure that hurts** | Decide what to measure per step from how it lets users down: availability (did the request succeed?), latency (was it fast enough?), or dependency availability (did a downstream call it relies on succeed?) | Phase 3.3 (assign a category and shape) |
| 3 | **Write the good and valid rules in words before any query** | State in plain English which events count at all (valid, for example all real checkout requests) and which count as success (good, for example returned HTTP 2xx); the query just encodes those sentences, so write them first | Phase 4.4 (write the good/valid definition) |
| 4 | **Set the target from measured performance, not a wish** | Measure how the service actually does first, then set the SLO just below that over a rolling window (for example 7 days); the error budget (the failure you allow) is then simply 100% minus the target | Phase 4.2 + Phase 5 (measure, then set target/window/budget) |
| 5 | **Alert on how fast the budget is draining, not the raw number** | Trigger on error-budget burn rate (how quickly you are using up the allowed failure): a fast-burn rule that pages for sudden drops, a slow-burn rule that files a ticket for steady erosion | Phase 5 + Phase 6.3 (burn-rate policy, then wire the alerts) |
| 6 | **Emit the metric with the labels the SLI needs, and keep it flowing** | The engine can only separate good from total using labels actually on the metric (for example `service`, `status_class`), so add them at the source or in a recording rule; and keep traffic flowing, because an empty window publishes nothing | Phase 4.1 (confirm dimensions) + the recording rules `deploy-sli.ps1` creates |
| 7 | **Translate each design decision into a Create-SLI form field** | Every choice above (type, good/total signals, target, window, alerts) maps to a specific field in the Azure "Create SLI" wizard, once the managed identity and its permissions are in place | Phase 6.0-6.4 (pre-flight + field-by-field walkthrough) |
| 8 | **Verify the SLI actually runs and publishes, do not trust the portal** | Confirm it provisioned, is running, and is writing its result series back to the workspace, then check that number against your own calculation from the source metric | Phase 7 (validate end-to-end) |
| 9 | **Review the target over time and adjust** | Check monthly: if the budget is never spent the target is too loose (tighten it); if it is always blown the target is too tight or the service needs reliability work | after the lab (ongoing) |

The lab's **Phase 6** carries the exact "design decision -> Create SLI form field" mapping and the identity, RBAC, and dimension-indexing prerequisites the wizard assumes, so they are not repeated here.

---

## 7\. Gotchas that cost real debugging time

These reinforce the rules in Section 6; the ones below are the least obvious.

1.  **A dashboard can lie about gaps.** Wide `increase()`/`avg_over_time()` windows carry the last value across gaps and make missing data look present. Add a raw, un-masked "source data present (1/0)" panel to tell the truth about continuity.
2.  **A small SLI dip can be a huge SLO breach.** With a 0.5% budget, a metric "only" dropping to 95% is a ~10x burn and exhausts the budget in well under a day. Always pair the SLI % with error budget + burn rate so the severity is visible.
3.  **Latency SLIs can be request-based or window-based.** This demo uses the **request-based** shape (proportion of login requests under 300 ms), built on counter signals that register reliably and never go `NaN`. The **window-based** alternative ("P95 \<= 300 ms" judged per 5-minute window, SLI = fraction of good windows) is the right tool when you cannot label individual events; there a sustained latency breach drives the value toward 0% window by window.

---

## 8\. Worksheet and recap

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
  SLO target = 99.5%   Window = 7 rolling days
  Error budget = 0.5%
  Burn-rate alert: fast 14.4x/1h (page), slow 1x/6h (ticket)
```

**Recap.** Start with the user, not the machine: turn their goal into countable events, label each good or valid, and the ratio is your **SLI**. Add a target and a rolling window to get an **SLO**; one minus the target is the **error budget**; how fast you spend it is the **burn rate**; and you alert on burn rate, not raw numbers. Define the **SLO** (what "good enough" means) before the **SLI** (how you measure it), even though the tooling asks for the SLI signals first.

---

## 9\. Reliability talking points for the customer

Use these to frame the demo for a business audience, once the SLI theory above is in place:

*   **Error budget =** `**100% - SLO**`**.** At 99.5% the budget is 0.5%. For ~25.9M checkout requests/30 days, that is roughly **129,500 failed requests** before the SLO is missed. This reframes "is it down?" into "how much failure can we still absorb?".
*   **Fast burn** catches sudden regressions (a bad deploy) early enough to roll back before the monthly budget is gone. **Slow burn** catches death-by-a-thousand-cuts degradation that single-threshold alerts miss.
*   SLIs are a **standard, cross-service signal**, so reliability conversations and release/incident decisions use one consistent language across the whole application.

---

## 10\. Mapping the demo to Azure Monitor SLI features

Each part of the demo demonstrates a specific SLI/SLO capability:

| Slide / concept | Demo action | Azure Monitor feature |
| --- | --- | --- |
| What is SLI/SLO | Show CheckoutSG with availability + latency SLIs | SLI types, baseline = SLO |
| Traditional vs SLI monitoring | Compare App Insights CPU/500 charts with SLI error budget | User-centric measurement |
| Pre-req: Service Group | Create `CheckoutSG` | Service group boundary |
| Common scenarios (login/checkout) | Author availability for checkout, latency for login | Request-based, latency evaluation |
| Error budget burns too fast | Inject 8% errors | Fast-burn alert |
| Sustained degradation | Inject +600 ms latency | Slow-burn alert |
| Manage SLIs view | Show list with status + error budget remaining | View and manage SLIs |