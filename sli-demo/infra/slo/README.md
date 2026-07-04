# Phase 2: Service Group and SLI authoring (Infrastructure as Code)

This folder automates the second phase of the demo: turning the running App Service
workload (deployed by [`../deploy.ps1`](../deploy.ps1)) into a measured, SLO-tracked
service using Azure Monitor **Service Groups** and **SLIs**.

## What gets created

| Resource | Type | Scope | Purpose |
| --- | --- | --- | --- |
| `slidemo-sli-recording-rules` | `Microsoft.AlertsManagement/prometheusRuleGroups` | Resource group (the workspace RG) | Pre-aggregates raw metrics into SLI-ready metrics that expose dimensions. |
| `CheckoutSG-<suffix>` | `Microsoft.Management/serviceGroups` | Tenant | The Service Group that the SLIs hang off. |
| Service Group member | `Microsoft.Relationships/serviceGroupMember` | Resource group | Adds `rg-sli-demo` to the Service Group. |
| `CheckoutAvailabilitySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Checkout request success rate, target 99.9%. |
| `LoginLatencySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Login P95 latency at or below 300 ms, target 99% of windows. |
| `PaymentDependencySLI` | `Microsoft.Monitor/slis` | Service Group (extension) | Payment dependency success rate, target 99.5%. |

## Files

- [`recording-rules.bicep`](recording-rules.bicep) - the Prometheus recording rules. Resource-group scoped.
- [`servicegroup-sli.bicep`](servicegroup-sli.bicep) - declarative tenant-scoped Service Group plus the three SLIs.
- [`deploy-slo.ps1`](deploy-slo.ps1) - one-stop, idempotent orchestrator. Recommended entry point.

## Run it

From this folder, with the main deployment already in place:

```powershell
./deploy-slo.ps1
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
| `sli:http_request_latency_p95:5m` | `service` | Login latency |
| `sli:http_request_latency_avg:5m` | `service` | Alternative latency signal |

## Timing note: metric-dimension indexing

After the recording rules first run, the workspace needs time to register the new
metrics and their dimensions in the metrics metadata store that the SLI query
validator uses. Until that indexing completes, SLI creation returns
`Name '<dimension>' does not exist in current context`. `deploy-slo.ps1` handles this
by retrying SLI creation (see `-SliIndexingRetryMinutes`, default 25). If a run times
out before indexing finishes, simply run the script again; it is idempotent.

## Declarative alternative

[`servicegroup-sli.bicep`](servicegroup-sli.bicep) expresses the Service Group and the
three SLIs declaratively for review, policy, or CI use. Because the Service Group is a
tenant resource, deploy it at tenant scope:

```powershell
az deployment tenant create `
  --location eastus2 `
  --template-file servicegroup-sli.bicep `
  --parameters serviceGroupName=CheckoutSG-<suffix> `
               azureMonitorWorkspaceId=<amw-resource-id> `
               sliManagedIdentityId=<uami-resource-id>
```

The resource-group membership relationship is resource-group scoped, so it stays in
`deploy-slo.ps1` rather than this tenant-scoped template.
