# Phase 2: Service Group and SLI authoring (Infrastructure as Code)

This folder automates the second phase of the demo: turning the running App Service
workload (deployed by [`../infra-deploy.ps1`](../infra-deploy.ps1)) into a measured, SLO-tracked
service using Azure Monitor **Service Groups** and **SLIs**.

## What gets created

| Resource | Type | Scope | Purpose |
| --- | --- | --- | --- |
| `slidemo-sli-recording-rules` | `Microsoft.AlertsManagement/prometheusRuleGroups` | Resource group (the workspace RG) | Pre-aggregates raw metrics into SLI-ready metrics that expose dimensions. |
| `CheckoutSG-<suffix>` | `Microsoft.Management/serviceGroups` | Tenant | The Service Group that the SLIs hang off. |
| Service Group member | `Microsoft.Relationships/serviceGroupMember` | Resource group | Adds `rg-sli-demo` to the Service Group. |
| `CheckoutAvailabilitySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Checkout request success rate, target 99.5%. |
| `LoginLatencySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Login latency: proportion of login requests under 300 ms, target 99.5%. |
| `PaymentDependencySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Payment dependency success rate, target 99.5%. |

## Files

- [`recording-rules.bicep`](recording-rules.bicep) - the Prometheus recording rules. Resource-group scoped.
- [`deploy-sli.ps1`](deploy-sli.ps1) - one-stop, idempotent orchestrator. Recommended entry point.

## Run it

From this folder, with the main deployment already in place:

```powershell
./deploy-sli.ps1
```

The script:

1. Reads the main deployment outputs (workspace ID, managed identity, naming suffix).
2. Deploys the recording rules into the workspace's resource group.
3. Creates the tenant Service Group under the tenant root group.
4. Adds the resource group to the Service Group as a member.
5. Waits for the recording-rule metrics to start producing data.
6. Creates the three SLIs and polls each until provisioning completes.

Keep traffic flowing while you run it so the metrics have data:

```powershell
$env:TARGET = "https://slidemo-fe-<suffix>.azurewebsites.net"
node ../../load/generate-traffic.js --rps 25 --duration 1800
```

## Why recording rules are required

SLIs read their source metrics from the Azure Monitor Workspace through the metrics
metadata bridge. That bridge only exposes **dimensions** (the labels you filter and
group by, such as `service` or `status_class`) for metrics produced by a recording
rule. Raw remote-written Prometheus series carry the labels in PromQL but expose no
dimensions to the SLI query engine, so an SLI built directly on them fails validation
with `Name 'service' does not exist in current context`.

The recording rules in [`recording-rules.bicep`](recording-rules.bicep) re-emit the
metrics with explicit `by (...)` grouping, which registers those labels as dimensions:

| Recording-rule metric | Grouped by | Feeds |
| --- | --- | --- |
| `sli:http_requests:rate5m` | `service`, `status_class` | Checkout availability |
| `sli:dependency_calls:rate5m` | `dependency`, `status` | Payment dependency availability |
| `sli:http_request_latency_good:rate5m` | `service` | Login latency (good = requests under 300 ms) |
| `sli:http_request_latency_total:rate5m` | `service` | Login latency (total requests) |
| `sli:http_request_latency_p95:5m` | `service` | Not used by SLIs (kept for ad-hoc charts) |
| `sli:http_request_latency_avg:5m` | `service` | Not used by SLIs (kept for ad-hoc charts) |

## Timing note: metric-dimension indexing

After the recording rules first run, the workspace needs time to register the new
metrics and their dimensions in the metrics metadata store that the SLI query
validator uses. Until that indexing completes, SLI creation returns
`Name '<dimension>' does not exist in current context`. `deploy-sli.ps1` handles this
by retrying SLI creation (see `-SliIndexingRetryMinutes`, default 25). If a run times
out before indexing finishes, simply run the script again; it is idempotent.
