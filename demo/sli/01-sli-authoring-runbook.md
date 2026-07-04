# Runbook 1: Author the SLIs in the portal

SLIs are authored at the **Service Group** level. The portal flow has four tabs: **Basics**, **SLI**, **Baseline + Alert**, and **Review + create**.

## Before you start

- Your Service Group (a unique name such as `CheckoutSG-<suffix>`, see README step 5.2) exists and has the resource group **`rg-sli-demo`** added as a member, so the frontend, backend, and Azure Monitor Workspace are all in scope.
- `http_server_requests_total`, `http_server_request_duration_seconds`, and `dependency_calls_total` are visible in the Azure Monitor Workspace.
- **Enable monitoring on the Service Group and set defaults.** Open the Service Group > **Monitoring**. If the SLI card shows *"No SLIs"* with a note to enable monitoring, select **Configure settings** and associate:
  - a **default Managed Identity** = the user-assigned identity deployed by `infra/` (`<prefix>-id-<suffix>`), and
  - a **default Azure Monitor Workspace** = `<prefix>-amw-<suffix>`.

  This is required. The Create SLI form reads these defaults; without them it shows *"This service group (SG) doesn't have a default MI or AMW configured."* You can still pick the identity and workspace per SLI, but setting SG defaults makes every SLI form pre-populated.

Open the Service Group > **Monitoring** > **Service Level Indicators (SLIs)** card > **Create SLIs**.

---

## SLI 1: CheckoutAvailabilitySLI (availability)

**Basics tab**
- Service Group: shown read-only (your `CheckoutSG-<suffix>`)
- SLI type: **Availability**
- SLI name: `CheckoutAvailabilitySLI`
- SLI description: `Percent of checkout requests returning 2xx`

**SLI tab**
- *Metrics details* > Evaluation method: **Request Count Based**
- *Identity and data source*:
  - Managed Identity: the user-assigned identity (`<prefix>-id-<suffix>`)
  - Data source: the Azure Monitor Workspace (`<prefix>-amw-<suffix>`)
- *SLI Details*:
  - **Good signal(s)** > **+ Add Metric**: `http_server_requests_total`, filters `service = checkout` and `status_class = 2xx`, temporal aggregation **Rate** (or Sum over the interval).
  - **Total signal(s)** > **+ Add Metric**: `http_server_requests_total`, filter `service = checkout`, temporal aggregation **Rate** (or Sum).
  - Click **Validate** and confirm the **Good Signal Preview** and **Total Signal Preview** charts render and the ratio sits near 1.0 under healthy traffic.
- *Identity and Data storage location* (where evaluated results are written):
  - Managed Identity: same user-assigned identity
  - Storage location: the same Azure Monitor Workspace (source and destination can be the same)

**Baseline + Alert tab**
- Baseline (SLO): `99.9`
- Evaluation period: `7` `rolling` day(s) (add a 30-day SLI later to show the monthly view)
- Alerts: select **Enable Alert** and configure per Runbook 2.

**Review + create tab**
- Review the summary and select **Create**.

---

## SLI 2: LoginLatencySLI (latency)

**Basics tab**
- SLI type: **Latency**
- SLI name: `LoginLatencySLI`

**SLI tab**
- Evaluation method: **Request Count Based**
- Managed Identity + Data source: same identity and Azure Monitor Workspace
- Signal metric: `http_server_request_duration_seconds`, filter `service = login`, temporal aggregation **P95**
- Latency threshold: `300` ms (a request is "good" if under 300 ms)
- **Validate** to preview
- Data storage location: same identity + workspace

**Baseline + Alert tab**
- Baseline (SLO): `95` (percent of requests under the latency threshold)
- Evaluation period: `7` `rolling` day(s)

**Review + create tab** > **Create**

---

## SLI 3: PaymentDependencySLI (dependency availability, formula)

**Basics tab**
- SLI type: **Availability**
- SLI name: `PaymentDependencySLI`

**SLI tab**
- Evaluation method: **Request Count Based**
- Managed Identity + Data source: same identity and Azure Monitor Workspace
- **Good signal(s)**: `dependency_calls_total`, filters `dependency = payment` and `status = ok`
- **Total signal(s)**: `dependency_calls_total`, filter `dependency = payment`
- If you need to combine metrics, use **+ Add Metric** for each, then **+ Add formula** (for example `ok / total`)
- **Validate**
- Data storage location: same identity + workspace

**Baseline + Alert tab**
- Baseline (SLO): `99.9`
- Evaluation period: `7` `rolling` day(s)

**Review + create tab** > **Create**

---

## Window-based alternative

To demo **Window based** evaluation instead of Request Count Based, choose it in *Metrics details*. You do not supply explicit good/total signals; instead you define a single signal and an **evaluation criteria** (threshold) that marks each time window good or bad. Use this to smooth short bursts of poor performance.

---

## Verify

Go to the Service Group > **Monitoring** > **View all SLIs** (or the **Manage SLIs** page). You should see all three with **Evaluation method**, **Type**, **Baseline and time window**, **SLI status**, and **Error budget remaining**. Drill into `CheckoutAvailabilitySLI` to view trend, error budget, and burn-rate charts.
