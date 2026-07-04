# Health Model Lab

A hands-on lab that takes you from the running SLI demo application to a complete **Azure Monitor
health model**: create the model, discover the app as entities, tap into the SLI Azure Monitor
Workspace (AMW) with PromQL signals, configure health-state alerts, and view the result. Every step
here was executed to build the working demo, so you can replicate it exactly.

This lab is a **reusable template**: run it against your own application by substituting your resource
names. Throughout, the **Checkout / Login** demo is filled in as the worked example.

How this fits with the other document in this folder:

- [Health-Model-Design-Guide.md](Health-Model-Design-Guide.md) is the theory-plus-process reference
  (entities, signals, rollup, discoveries, alerts). Read it first if the vocabulary is new.
- **This lab** is the executable version: the actual commands and the scripts that wrap them.

Everything can be run two ways: the **scripted path** (three PowerShell scripts) or the **manual
path** (the underlying `az` commands). Both are shown.

---

## Lab conventions

Placeholders you substitute once and reuse everywhere:

| Placeholder | Meaning | Demo value |
| --- | --- | --- |
| `<hm-rg>` | New resource group holding the health model | `rg-healthmodel-demo` |
| `<hm>` | Health model name | `hm-checkout-demo` |
| `<hm-region>` | Region for the health model (CloudHealth-supported) | `centralus` |
| `<sli-rg>` | Resource group holding the SLI app, App Insights, and AMW | `rg-sli-demo` |
| `<suffix>` | Unique suffix from the SLI deployment | `ioarvugvrpkmc` |
| `<ai>` | Application Insights component to discover | `slidemo-ai-<suffix>` |
| `<amw>` | Azure Monitor Workspace (SLI metrics source) | `slidemo-amw-<suffix>` |

Commands are PowerShell (the workspace default shell). Signal queries are PromQL against the AMW.

> The live provider is **`Microsoft.CloudHealth`** (API `2026-05-01-preview`), and health models are
> only available in these regions: uksouth, canadacentral, centralus, swedencentral, southeastasia,
> switzerlandnorth, italynorth, northeurope, germanywestcentral, australiaeast.

---

## Part 0: Environment setup and access checks

**Goal:** confirm the prerequisites before you build anything.

### 0.1 Select your subscription

```powershell
az login                                              # if not already signed in
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id, tenant:tenantId}" -o table
```

### 0.2 Confirm the SLI demo exists (the app to represent)

The health model discovers an existing Application Insights and taps an existing AMW, so the SLI demo
must be deployed first (see `../sli-demo/infra/deploy.ps1`).

```powershell
$SliRg = 'rg-sli-demo'
# Application Insights to discover:
az resource list -g $SliRg --resource-type 'Microsoft.Insights/components' --query "[].{name:name,id:id}" -o table
# Azure Monitor Workspace to tap for PromQL signals:
az resource list -g $SliRg --resource-type 'Microsoft.Monitor/accounts'   --query "[].{name:name,id:id}" -o table
```

If either is empty, deploy the SLI demo first, then continue.

### 0.3 (Recommended) generate traffic

Signals read **Unknown** until the metrics have data. Run the SLI traffic generator so the App
Insights topology is populated and the AMW metrics report values:

```powershell
node ../sli-demo/load/generate-traffic.js --rps 15 --duration 900
```

---

## Part 1: Create the health model

**Goal:** create the model with a system-assigned identity and grant it read access to the app.

### Scripted path

```powershell
cd healthmodel-demo
./deploy.ps1        # defaults: -ResourceGroup rg-healthmodel-demo -Location centralus -SliResourceGroup rg-sli-demo
```

`deploy.ps1` performs Parts 1 and 2. The manual equivalents are below.

### Manual path

```powershell
$HmRg     = 'rg-healthmodel-demo'
$Hm       = 'hm-checkout-demo'
$Region   = 'centralus'
$SliRg     = 'rg-sli-demo'

# 1. Resource group + provider
az group create -n $HmRg -l $Region -o none
az provider register --namespace Microsoft.CloudHealth -o none

# 2. Create the health model with a system-assigned managed identity (Basics + Identity tabs)
$hm = az monitor health-models create -g $HmRg -n $Hm -l $Region --system-assigned -o json | ConvertFrom-Json
$hmId        = $hm.id
$principalId = $hm.identity.principalId

# 3. Grant Monitoring Reader on the SLI resource group so discovery can read telemetry
$sliRgId = az group show -n $SliRg --query id -o tsv
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role 'Monitoring Reader' --scope $sliRgId
```

> The `health-models` CLI extension installs automatically on first use. It is preview.

---

## Part 2: Discover the app as entities

**Goal:** import the Login and Checkout components from Application Insights.

### Manual path

```powershell
$api = '2026-05-01-preview'
$mgmt = 'https://management.azure.com'
$aiId = az resource list -g $SliRg --resource-type 'Microsoft.Insights/components' --query '[0].id' -o tsv

# 2a. Authentication setting bound to the system-assigned identity
$authBody = @{ properties = @{ authenticationKind='ManagedIdentity'; managedIdentityName='SystemAssigned'; displayName='System-assigned managed identity' } } | ConvertTo-Json -Depth 5
$authBody | Set-Content auth.json
az rest --method put --url "$mgmt$hmId/authenticationsettings/system-assigned?api-version=$api" --headers 'Content-Type=application/json' --body '@auth.json'

# 2b. Application Insights topology discovery rule (note: kind + AI id go inside properties.specification)
$drBody = @{ properties = @{
  specification         = @{ kind='ApplicationInsightsTopology'; applicationInsightsResourceId=$aiId }
  authenticationSetting = 'system-assigned'
  displayName           = 'Checkout/Login App Insights topology'
  discoverRelationships = 'Enabled'
  addRecommendedSignals = 'Enabled'
} } | ConvertTo-Json -Depth 8
$drBody | Set-Content discovery.json
az rest --method put --url "$mgmt$hmId/discoveryrules/appinsights-topology?api-version=$api" --headers 'Content-Type=application/json' --body '@discovery.json'
```

### Verify (after ~5 to 10 minutes)

```powershell
az monitor health-models entity list -g $HmRg --health-model-name $Hm `
  --query "[].properties.displayName" -o tsv
```

Expected to include `sli-demo-frontend` (Login), `sli-demo-backend` (Checkout), and a
`failure anomalies` detector. Discovery also attaches a recommended Log Analytics "failed requests"
signal to each app entity.

---

## Part 3: Tap into the SLI AMW (configure signals)

**Goal:** add PromQL signals sourced from the SLI Azure Monitor Workspace, so the health model reads
the same reliability metrics the SLIs are built on.

### Scripted path

```powershell
./configure-signals-alerts.ps1
```

This grants Monitoring Reader on the AMW, then adds an **Azure Monitor workspace** signal to each app
entity (Parts 3 and 4). The mapping:

| Entity | Signal | PromQL | Degraded | Unhealthy |
| --- | --- | --- | --- | --- |
| `sli-demo-backend` (Checkout) | Availability % | `100 * sum(rate(http_server_requests_total{service="checkout",status_class="2xx"}[5m])) / sum(rate(http_server_requests_total{service="checkout"}[5m]))` | `< 100` | `< 99` |
| `sli-demo-frontend` (Login) | p95 latency (ms) | `1000 * max(sli:http_request_latency_p95:5m{service="login"})` | `> 200` | `> 300` |

### Manual path (per entity)

The API replaces the entity on PUT, so **GET the entity, add the `azureMonitorWorkspace` signal group,
drop runtime fields, and PUT it back**:

```powershell
$amwId = az resource list -g $SliRg --resource-type 'Microsoft.Monitor/accounts' --query '[0].id' -o tsv
# Monitoring Reader on the AMW for PromQL query access
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role 'Monitoring Reader' --scope $amwId

# Resolve the entity's (GUID) name from its display name
$name = (az monitor health-models entity list -g $HmRg --health-model-name $Hm -o json | ConvertFrom-Json |
  Where-Object { $_.properties.displayName -eq 'sli-demo-backend' }).name

# GET, add the AMW signal group, PUT (see configure-signals-alerts.ps1 for the full clone/merge helper)
$e = az monitor health-models entity show -g $HmRg --health-model-name $Hm --entity-name $name -o json | ConvertFrom-Json
# ... build $props from $e.properties (drop status/healthState/provisioningState),
#     set $props.signalGroups.azureMonitorWorkspace = @{ authenticationSetting='system-assigned'
#         azureMonitorWorkspaceResourceId=$amwId; signals=@(<PromeQL signal>) } ...
```

> Use `configure-signals-alerts.ps1` rather than hand-rolling the merge: it preserves the discovered
> Log Analytics signals, coerces single-element `signals` arrays, and strips read-only fields.

---

## Part 4: Configure alerts

**Goal:** fire an alert when an entity changes health state (not per raw metric).

`configure-signals-alerts.ps1` sets, on the same PUT, an `alerts` block on each app entity:

| State | Severity | Notes |
| --- | --- | --- |
| Degraded | `Sev2` | fires when the entity enters Degraded |
| Unhealthy | `Sev1` | fires when the entity enters Unhealthy |

Attach action groups (optional, up to 5):

```powershell
./configure-signals-alerts.ps1 -ActionGroupId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/actionGroups/<ag>"
```

The `alerts` shape written to `properties.alerts`:

```json
{
  "degraded":  { "severity": "Sev2", "description": "...", "actionGroupIds": ["<optional>"] },
  "unhealthy": { "severity": "Sev1", "description": "...", "actionGroupIds": ["<optional>"] }
}
```

---

## Part 5: View and validate

```powershell
# Model state
az monitor health-models show -g $HmRg -n $Hm --query "{name:name,location:location,state:properties.provisioningState,identity:identity.type}" -o jsonc

# Discovery rule
az monitor health-models discovery-rule list -g $HmRg --health-model-name $Hm `
  --query "[].{name:name,state:properties.provisioningState,spec:properties.specification}" -o jsonc

# An entity's signals + alerts
$name = (az monitor health-models entity list -g $HmRg --health-model-name $Hm -o json | ConvertFrom-Json |
  Where-Object { $_.properties.displayName -eq 'sli-demo-backend' }).name
$e = az monitor health-models entity show -g $HmRg --health-model-name $Hm --entity-name $name -o json | ConvertFrom-Json
$e.properties.signalGroups.PSObject.Properties.Name          # azureLogAnalytics, azureMonitorWorkspace
$e.properties.signalGroups.azureMonitorWorkspace.signals[0]  # the AMW PromQL signal
$e.properties.alerts                                         # Degraded/Unhealthy
```

In the **portal**: open the health model > **Graph view** to see Login and Checkout as entities;
drill into an entity to see its **Signals** and **Alerts** tabs. With live traffic (Part 0.3), the AMW
signals move from **Unknown** to **Healthy / Degraded / Unhealthy**.

---

## Part 6: Teardown

```powershell
./teardown.ps1                      # delete the health model + remove role assignments
./teardown.ps1 -DeleteResourceGroup # also delete rg-healthmodel-demo
```

The SLI demo (`rg-sli-demo`) is never touched.

---

## Appendix: scripts in this folder

| Script | Covers | Lab parts |
| --- | --- | --- |
| [deploy.ps1](deploy.ps1) | Create model + identity + role + auth setting + App Insights discovery | 1, 2 |
| [configure-signals-alerts.ps1](configure-signals-alerts.ps1) | AMW Monitoring Reader + PromQL signals + alerts | 3, 4 |
| [teardown.ps1](teardown.ps1) | Delete model + remove role assignments | 6 |

## Appendix: what maps to which doc

| Doc | Lab part |
| --- | --- |
| [Create a health model](https://learn.microsoft.com/azure/azure-monitor/health-models/create) | Part 1 |
| [Discover entities (App Insights)](https://learn.microsoft.com/azure/azure-monitor/health-models/discoveries?tabs=app-insights) | Part 2 |
| [Configure signals (Azure Monitor workspace)](https://learn.microsoft.com/azure/azure-monitor/health-models/signals?tabs=azuremonitorworkspace) | Part 3 |
| [Configure alerts](https://learn.microsoft.com/azure/azure-monitor/health-models/alerts) | Part 4 |
