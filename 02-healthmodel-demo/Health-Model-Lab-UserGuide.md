# Health Model Lab: User Guide

A guided, end-to-end walkthrough of building an Azure Monitor **Health Model** (preview) on top of the  
SLIs authored by the SLI/SLO demo. It takes you from a deployed SLI demo to a working health model whose  
entity health is driven by the exact SLI values the Service Group already publishes.

There are two ways to run the 6-phase build (Phase 7 is a summary checklist), and both share the same  
Phase 0 setup and the same traffic prerequisite:

*   **Path A - Automated:** [healthmodel-run-lab.ps1](healthmodel-run-lab.ps1) drives Phases 1 to 6 in one pass, prompting only before the two write steps (create the model, configure signals).
*   **Path B - Manual:** run the `az` / PromQL commands yourself, phase by phase, to understand each step and adapt the build to your own application.

The health model is the **next phase after SLIs**. Where the SLI lab  
([../01-sli-demo/sli-run-lab.ps1](../01-sli-demo/sli-run-lab.ps1)) authors the Service Level Indicators, this lab turns  
those SLIs into a state-based, roll-up view of workload health. It derives its health signals directly  
from the `ns::<servicegroup>/m::<sli>:value` series in the Azure Monitor Workspace (the "sli label"), so  
health and reliability agree on the same numbers.

This guide reflects the current workflow, where **baseline traffic is a manual prerequisite** started in  
its own terminal before the lab runs (neither path starts or stops traffic for you).

## How this fits with the design guide

[Health-Model-Design-Guide.md](Health-Model-Design-Guide.md) is the concepts reference (entities, signals,  
relationships, roll-up). Read it first if the vocabulary is new. **This guide is the executable version:**  
the actual commands and expected output.

---

## Table of contents

*   [What the lab does](#what-the-lab-does)
*   [How the SLI label drives the health model](#how-the-sli-label-drives-the-health-model)
*   [Why traffic must be running first](#why-traffic-must-be-running-first)
*   [Prerequisites](#prerequisites)
*   [Phase 0: deploy the SLI demo and start traffic (both paths)](#phase-0-deploy-the-sli-demo-and-start-traffic-both-paths)
*   [Path A: Run the automated build (healthmodel-run-lab.ps1)](#path-a-run-the-automated-build-healthmodel-run-labps1) - [Parameters](#parameters), [Examples](#examples), [New vs existing](#new-vs-existing-health-model), [Full run output](#full-run-output-all-phases-interactive-mode)
*   [Path B: Run the build by hand (command-by-command)](#path-b-run-the-build-by-hand-command-by-command) - [Phase 1](#phase-1-environment-setup-and-access-checks), [2](#phase-2-create-the-health-model), [3](#phase-3-discover-the-app-as-entities), [4](#phase-4-map-the-slis-to-entities), [5](#phase-5-configure-signals-and-alerts), [6](#phase-6-validate-end-to-end)
*   [Outputs](#outputs), [Example run output](#example-run-output), [Troubleshooting](#troubleshooting), [How this maps to the Azure docs](#how-this-maps-to-the-azure-docs), [Portal fallback](#portal-fallback-if-the-preview-cliapi-changes), [Related files](#related-files)

---

## What the lab does

The build has 6 phases (Phase 7 is a summary checklist). The automated runner (`healthmodel-run-lab.ps1`,  
Path A) maps one-to-one to the manual phases (Path B). Phase 2 creates the model + two discovery nodes,  
Phase 5 configures the signals:

| Phase | Title | Mode |
| --- | --- | --- |
| 1 | Environment setup and access checks | auto + confirm |
| 2 | Create the health model | optional `src/healthmodel-deploy.ps1` (idempotent) |
| 3 | Discover the app as entities (Resource Graph + App Insights topology nodes) | auto verify |
| 4 | Map the SLIs to entities (derive from the sli label) | auto (writes CSV) |
| 5 | Configure signals + alerts | optional `src/configure-signals-alerts.ps1` |
| 6 | Validate end-to-end | auto |

Phase 0 (infrastructure) is not part of this script. Deploy the SLI demo first with  
[../01-sli-demo/infra/infra-deploy.ps1](../01-sli-demo/infra/infra-deploy.ps1) and author the SLIs with  
[../01-sli-demo/infra/sli/deploy-sli.ps1](../01-sli-demo/infra/sli/deploy-sli.ps1).

---

## How the SLI label drives the health model

The runner keeps no manual mapping table. For each SLI, it derives the target automatically:

1.  **Enumerate** the SLIs authored on the Service Group from the control plane (the Service Group's  
    `slis` collection).
2.  **Read the sli label**: the `service=` or `dependency=` the SLI measures (for example  
    `service=checkout`, `service=login`, `dependency=payment`).
3.  **Confirm** the `ns::<servicegroup>/m::<sli>:value` series exists in the Azure Monitor Workspace.
4.  **Map** the SLI to the App Service entity that serves that part of the journey: services named in  
    `-FrontendServices` (default `login`) map to the frontend App Service, every other service or  
    dependency maps to the backend App Service.

Phase 5 then attaches one Azure Monitor workspace (PromQL) signal per SLI to the mapped entity, so the  
entity health state is driven by the stored SLI value.

---

## Why traffic must be running first

Every SLI is a **rate over a rolling window**, and the health signals read the SLI `:value` series the  
engine publishes. If the app is not receiving traffic, the SLI series go stale and the health signals  
read "Unknown". Because of this, the SLI app must already be receiving continuous traffic **before** you  
run the lab.

The runner script does not start or stop traffic for you. It only checks in Phase 1.5 that the SLI  
`:value` series carry recent data; if they do not, it tells you to start the generator and re-run.

---

## Prerequisites

1.  **PowerShell 7+** and **Azure CLI** signed in (`az login`) to the correct subscription.
2.  The **SLI demo deployed** in `rg-sli-demo` and its **SLIs authored** on the Service Group.
3.  The `health-models` Azure CLI extension (installs automatically on first use).
4.  `Microsoft.CloudHealth` is region-limited; the health model resource group uses `centralus` by  
    default (this is independent of where the SLI demo lives).

---

## Phase 0: deploy the SLI demo and start traffic (both paths)

### Step 1: deploy the SLI demo and author the SLIs (SLI lab prerequisite)

This step belongs to the **SLI lab** ([../01-sli-demo/sli-run-lab.ps1](../01-sli-demo/sli-run-lab.ps1)); this health  
model lab is its continuation. If you already ran the SLI lab in this environment, the SLI demo and its  
SLIs are in place, so **skip to Step 2**.

If the SLI lab was **not** done (no `rg-sli-demo`, or the Service Group has no authored SLIs), start  
fresh here. Deploy the demo infrastructure and author the SLIs with `deploy-sli.ps1`, one-time per  
environment:

```
cd 01-sli-demo
./infra/infra-deploy.ps1 -ResourceGroup rg-sli-demo -Location eastus2
./infra/sli/deploy-sli.ps1 -ResourceGroup rg-sli-demo
```

`deploy-sli.ps1` creates the recording rules, the tenant-scoped Service Group, membership, monitoring  
defaults, and the three SLIs. It is idempotent, so it is safe to run even if some of those already exist.  
Resource names carry a generated suffix (for example `slidemo-fe-<suffix>`), which this lab discovers  
automatically.

### Step 2 (prerequisite for the lab): start the traffic generator in a separate terminal

Leave this running for the whole lab. The frontend URL is discovered automatically:

```
# Terminal 1 (leave running)
cd 01-sli-demo
pwsh -File load/generate-traffic-all.ps1 -ResourceGroup rg-sli-demo -Rps 30 -DurationSeconds 1800
```

Give it 1 to 2 minutes so the SLI engine publishes recent `:value` samples.

## Path A: Run the automated build (healthmodel-run-lab.ps1)

### Step 3: run the lab

```
# Terminal 2
cd 02-healthmodel-demo
./healthmodel-run-lab.ps1
```

Interactive runs pause at each phase and confirm before the two write steps (`src/healthmodel-deploy.ps1` in Phase 2 and  
`src/configure-signals-alerts.ps1` in Phase 5). For an unattended pass that accepts sensible defaults, add  
`-NonInteractive`.

If Phase 1.5 reports the SLI series have no recent data, start the generator (Step 2), wait a couple of  
minutes, and re-run.

### Step 4: cleanup confirmation

At the end of an **interactive** run the script offers to delete the health model and its Monitoring  
Reader role assignment. The SLI demo is never touched:

```
Delete health model 'hm-checkout-demo' now? (y/N):
```

*   Answer `n` (or press Enter) to keep everything.
*   Answer `y` to run [teardown.ps1](teardown.ps1) immediately.

Under `-NonInteractive` this destructive step is **skipped automatically** (defaults to keeping the  
model) and the manual teardown command is printed instead, so unattended runs never block or delete.

---

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-SliResourceGroup` | `rg-sli-demo` | Where the SLI app, Application Insights, and Azure Monitor Workspace live. |
| `-MainDeploymentName` | `main` | Name of the SLI main deployment (for reading outputs). |
| `-ResourceGroup` | `rg-healthmodel-demo` | Health model resource group (created if missing). |
| `-Location` | `centralus` | Health model region (`Microsoft.CloudHealth` is region-limited). |
| `-HealthModelName` | `hm-checkout-demo` | Health model resource name. |
| `-Subscription` | current | Optional subscription to select first. |
| `-Amw` / `-Ai` | discovered | Azure Monitor Workspace / Application Insights names. |
| `-ServiceGroup` | discovered / `CheckoutSG-<suffix>` | Tenant-scoped Service Group that owns the SLIs. |
| `-FrontendServices` | `@('login')` | Services whose SLIs map to the frontend App Service; everything else maps to the backend. |
| `-FrontendLike` / `-BackendLike` | `*-fe-*` / `*-be-*` | Display-name patterns used to resolve the App Service entities. |
| `-ActionGroupId` | none | Optional action group to notify when an entity alert fires. |
| `-StartPhase` / `-EndPhase` | `1` / `6` | Run a subset of the phases below (Phase 1 setup always runs first): 1 Environment setup, 2 Create the health model, 3 Discover the app as entities, 4 Map the SLIs to entities, 5 Configure signals + alerts, 6 Validate end-to-end. See [What the lab does](#what-the-lab-does). |
| `-NonInteractive` | off | Accept every default without prompting (teardown is skipped, not prompted). |

> Traffic is started manually (Step 2), not by the script.

---

### Examples

All examples run from the `02-healthmodel-demo` folder.

Full interactive run with defaults (pauses at each phase, confirms before write steps):

```
./healthmodel-run-lab.ps1
```

Full unattended run (accepts defaults, skips the teardown prompt, keeps the model):

```
./healthmodel-run-lab.ps1 -NonInteractive
```

Re-map and reconfigure only, after entities are already discovered (Phases 4 to 6):

```
./healthmodel-run-lab.ps1 -NonInteractive -StartPhase 4 -EndPhase 6
```

Re-validate only, without changing anything (Phase 6):

```
./healthmodel-run-lab.ps1 -NonInteractive -StartPhase 6 -EndPhase 6
```

Target an explicit subscription and Service Group (skip auto-discovery of the group):

```
./healthmodel-run-lab.ps1 `
  -Subscription 463a82d4-1896-4332-aeeb-618ee5a5aa93 `
  -ServiceGroup CheckoutSG-ioarvugvrpkmc
```

Point at a differently named SLI environment (custom resource groups and names):

```
./healthmodel-run-lab.ps1 `
  -SliResourceGroup rg-sli-prod `
  -ResourceGroup rg-healthmodel-prod `
  -HealthModelName hm-checkout-prod `
  -Location eastus
```

Pin the Azure Monitor Workspace and Application Insights instead of discovering them:

```
./healthmodel-run-lab.ps1 -Amw slidemo-amw-ioarvugvrpkmc -Ai slidemo-ai-ioarvugvrpkmc
```

Adjust the SLI-to-entity mapping for a different app layout (which service is the frontend, and how the  
App Service entities are named):

```
./healthmodel-run-lab.ps1 `
  -FrontendServices @('login','browse') `
  -FrontendLike '*-web-*' `
  -BackendLike '*-api-*'
```

Wire an action group so entity alerts notify a team:

```
$agId = az monitor action-group show -g rg-ops -n oncall-ag --query id -o tsv
./healthmodel-run-lab.ps1 -NonInteractive -ActionGroupId $agId
```

---

### New vs existing health model

*   If the health model **does not exist**, Phase 2 creates it end-to-end via `src/healthmodel-deploy.ps1` (model +  
    system-assigned identity, Monitoring Reader on the SLI resource group, authentication setting, and the  
    Resource Graph discovery rule).
*   If it **already exists**, Phase 2 treats `src/healthmodel-deploy.ps1` as idempotent. It also **self-heals**: if the  
    model's identity is missing Monitoring Reader on the SLI resource group (discovery cannot read the app  
    without it), Phase 2 re-runs `src/healthmodel-deploy.ps1` automatically to reconcile the role and the discovery rule.

Phase 4 discovers the SLIs from the control plane, so the mapping always matches the SLIs that were  
actually authored, regardless of naming.

---

### Full run output (all phases, interactive mode)

> Illustrative capture from an earlier **single-node** run: it shows only the Azure Resource Graph
> discovery node, so its Phase 3/6 entity lists are shorter than a current run. The current build
> creates **two** discovery nodes (Azure Resource Graph + Application Insights topology), as shown in
> the two-node [Example run output](#example-run-output) below and the Design Guide graph. Recapture
> this section from your own run for an exact match.

Traffic generator already running in a separate terminal (Step 2). Command (no arguments = interactive,
prompts at each phase):

```
./healthmodel-run-lab.ps1
```

```
Health Model Lab - interactive runner
Phases 1 to 6

==============================================================================
  PHASE 1: Environment setup and access checks
==============================================================================
==> 1.1 - Select your subscription and confirm the SLI demo exists
    Subscription : 463a82d4-1896-4332-aeeb-618ee5a5aa93
    SLI resource group 'rg-sli-demo' found.
==> 1.2 - Discover the SLI resources the health model reads
    Application Insights : slidemo-ai-ioarvugvrpkmc
    Azure Monitor Workspace : slidemo-amw-ioarvugvrpkmc
==> 1.3 - Resolve the Service Group that owns the SLIs
Service Group name (tenant-scoped, owns the SLIs) [CheckoutSG-ioarvugvrpkmc]:
    Service Group 'CheckoutSG-ioarvugvrpkmc' exists.
==> 1.4 - Resolve the Prometheus query endpoint
    Endpoint: https://slidemo-amw-ioarvugvrpkmc-fzb4hzbqb4dgfxfq.eastus2.prometheus.monitor.azure.com
==> 1.5 - Confirm the SLI :value series carry recent data (traffic prerequisite)
    checkoutavailabilitysli = 99.751
    loginlatencysli = 100.000
    paymentdependencysli = 99.814
==> 1.6 - Choose the health model to create or update
    Microsoft.CloudHealth is region-limited; keep a supported region such as centralus.
    Existing health models in this subscription (select one to reuse, or create new):
      [0] hm-checkout-demo  (rg-healthmodel-demo / centralus)
      [1] od2  (healthmodel-rg / canadacentral)
      [n] Create a new health model
Select a model number to reuse, or n to create new [n]:
    New health model (press Enter to accept each default):
Health model name [hm-checkout-demo]: hm-test1
Health model resource group [rg-healthmodel-demo]: rg-hm-test1
Health model region [centralus]:

  Confirmed configuration:

Subscription      : 463a82d4-1896-4332-aeeb-618ee5a5aa93
SliResourceGroup  : rg-sli-demo
AMW               : slidemo-amw-ioarvugvrpkmc
AppInsights       : slidemo-ai-ioarvugvrpkmc
ServiceGroup      : CheckoutSG-ioarvugvrpkmc
HealthModel       : hm-test1
HealthModelRG     : rg-hm-test1
HealthModelRegion : centralus
HealthModelState  : new (Phase 2 creates it)
SliValueSeries    : 3

Proceed with these values? (Y/n): y
-- Phase 1 complete. Press Enter to continue:

==============================================================================
  PHASE 2: Create the health model
==============================================================================
    Creates the model + system-assigned identity, grants Monitoring Reader on the SLI
    resource group, binds the authentication setting, and creates the discovery rule.
    Health model 'hm-test1' does not exist yet.
Run src/healthmodel-deploy.ps1 now to create the model and discovery rule? (Y/n): y
==> 2.1 - Invoking src/healthmodel-deploy.ps1
==> Subscription: ME-MngEnvMCAP993834-varghesejoji-1 (463a82d4-1896-4332-aeeb-618ee5a5aa93)
==> Ensuring the health-models CLI extension is installed
==> Verifying SLI resource group rg-sli-demo
==> Ensuring resource group rg-hm-test1
==> Registering resource provider Microsoft.CloudHealth
==> Creating health model hm-test1 with a system-assigned identity
    Health model id: /subscriptions/.../resourceGroups/rg-hm-test1/providers/Microsoft.CloudHealth/healthmodels/hm-test1
    System identity principalId: 88b61894-2c96-46b8-bd32-1d43ecbbc4ae
==> Granting Monitoring Reader on rg-sli-demo to the health model identity
    Monitoring Reader assigned
==> Creating authentication setting (system-assigned managed identity)
    authentication setting created
==> Creating Resource Graph discovery rule (App Services + plan)
    discovery rule created
==> Linking the model root to the discovered topology (health roll-up)
    root -> topology created

==> Done. Health model deployed.
Health model:     hm-test1 (rg-hm-test1 / centralus)
Discovers:        App Services + plan in 'rg-sli-demo' (Resource Graph discovery)
Portal:           https://portal.azure.com/#@<tenant>/resource<hmId>/overview

Discovery runs every 5 minutes. Give it 5-10 minutes, then open the health model
in the portal (Graph view) to see the Checkout/Login components as entities.
Tip: run the SLI traffic generator first so App Insights has topology + dependencies to discover.
-- Phase 2 complete. Press Enter to continue:

==============================================================================
  PHASE 3: Discover the app as entities
==============================================================================
    Discovery runs on a fixed 5-minute cycle and imports the workload App Services as
    entities. This phase verifies the entities exist before signals are attached.
==> 3.1 - Enumerate discovered entities
    No app App Service entities yet. Discovery runs every 5 minutes.
Wait 60s and re-check? (Y/n): y
    No app App Service entities yet. Discovery runs every 5 minutes.
Wait 60s and re-check? (Y/n): y

DisplayName                       Role
-----------                       ----
slidemo-be-ioarvugvrpkmc-plan     supporting
slidemo-be-ioarvugvrpkmc          backend (Checkout)
slidemo-promproxy-ioarvugvrpkmc   supporting
slidemo-otelcolapp-ioarvugvrpkmc  supporting
Checkout/Login workload resources supporting
slidemo-fe-ioarvugvrpkmc          frontend (Login)
hm-test1                          supporting

    7 entities discovered.
-- Phase 3 complete. Press Enter to continue:

==============================================================================
  PHASE 4: Map the SLIs to entities (derive from the sli label)
==============================================================================
==> 4.1 - Enumerate the SLIs authored on the Service Group
    Authored SLIs: CheckoutAvailabilitySLI, LoginLatencySLI, PaymentDependencySLI
==> 4.2 - Derive the sli label and locate the published :value series

Sli                     Label              Role     Entity                    Value SeriesFound
---                     -----              ----     ------                    ----- -----------
CheckoutAvailabilitySLI service=checkout   backend  slidemo-be-ioarvugvrpkmc  99.87        True
LoginLatencySLI         service=login      frontend slidemo-fe-ioarvugvrpkmc 100.00        True
PaymentDependencySLI    dependency=payment backend  slidemo-be-ioarvugvrpkmc  99.87        True

==> 4.3 - Write the entity/SLI map
    Entity/SLI map written to ...\02-healthmodel-demo\healthmodel-entity-map.csv.
-- Phase 4 complete. Press Enter to continue:

==============================================================================
  PHASE 5: Configure signals + alerts
==============================================================================
    Attaches one Azure Monitor workspace (PromQL) signal per SLI to its mapped entity so
    the entity health is driven by the stored SLI value, and enables Degraded/Unhealthy
    state alerts. src/configure-signals-alerts.ps1 applies the mapping surfaced in Phase 4.
Run src/configure-signals-alerts.ps1 now? (Y/n): y
==> 5.1 - Invoking src/configure-signals-alerts.ps1
    AMW: /subscriptions/.../resourcegroups/rg-sli-demo/providers/microsoft.monitor/accounts/slidemo-amw-ioarvugvrpkmc
==> Ensuring AMW query roles (Monitoring Data Reader + Monitoring Reader) for the health model identity
    Monitoring Data Reader assigned
    Monitoring Reader assigned
==> Disabling auto-added recommended + resource-health signals on the discovery rule
    disabled
==> Discovering published SLI result series in the AMW
    CheckoutAvailabilitySLI: found
    LoginLatencySLI: found
    PaymentDependencySLI: found
==> Checkout (backend App Service) = 'slidemo-be-ioarvugvrpkmc': Checkout availability SLI (AMW), Payment dependency SLI (AMW)
    slidemo-be-ioarvugvrpkmc (Checkout availability SLI (AMW), Payment dependency SLI (AMW)) updated
==> Login (frontend App Service) = 'slidemo-fe-ioarvugvrpkmc': Login latency SLI (AMW)
    slidemo-fe-ioarvugvrpkmc (Login latency SLI (AMW)) updated
==> App Service plan tier: Free (Resource Health supported: False)
==> Uptime signal (CPU % (App Service plan)) on 'slidemo-be-ioarvugvrpkmc-plan'
    uptime slidemo-be-ioarvugvrpkmc-plan updated
==> Uptime signal (Uptime (HTTP 2xx)) on 'slidemo-promproxy-ioarvugvrpkmc'
    uptime slidemo-promproxy-ioarvugvrpkmc updated
==> Uptime signal (Uptime (HTTP 2xx)) on 'slidemo-otelcolapp-ioarvugvrpkmc'
    uptime slidemo-otelcolapp-ioarvugvrpkmc updated
==> Linking the model root to the topology so health rolls up
    root -> topology updated

==> Done. AMW signals and alerts configured.
Signals evaluate every minute. With no live traffic they read "Unknown"; run the SLI
traffic generator (../01-sli-demo/load/generate-traffic.js) to make them report a value.
Open the health model > entity > Signals / Alerts to review.
-- Phase 5 complete. Press Enter to continue:

==============================================================================
  PHASE 6: Validate end-to-end
==============================================================================
    Confirm each app entity carries its SLI signal(s), read the current health states, and
    confirm the model root rolls up the workload.
==> 6.1 - Entity health states and attached SLI signals

Entity                           Health  SliSignals
------                           ------  ----------
slidemo-be-ioarvugvrpkmc-plan    Healthy
slidemo-be-ioarvugvrpkmc         Healthy Checkout availability SLI (AMW), Payment dependency SLI (AMW)
slidemo-promproxy-ioarvugvrpkmc  Healthy
slidemo-otelcolapp-ioarvugvrpkmc Healthy
Checkout/Login workload          Healthy
slidemo-fe-ioarvugvrpkmc         Healthy Login latency SLI (AMW)
hm-test1                         Healthy

==> 6.2 - Confirm the SLI signals reference the stored :value series
    CheckoutAvailabilitySLI -> slidemo-be-ioarvugvrpkmc: stored SLI value = 99.868
    LoginLatencySLI -> slidemo-fe-ioarvugvrpkmc: stored SLI value = 100
    PaymentDependencySLI -> slidemo-be-ioarvugvrpkmc: stored SLI value = 99.868
==> 6.3 - Confirm the model root rolls up the topology
    Root 'hm-test1' links to 'appinsights-topology' (workload rolls up into the model root).
    Portal (Graph view): https://portal.azure.com/#@<tenant>/resource<hmId>/overview
-- Phase 6 complete. Press Enter to continue:

==============================================================================
  PHASE 7: Lab completion checklist
==============================================================================
    Phase 1: SLI resources resolved and the SLI :value series carry data.
    Phase 2: health model + system identity created, discovery rule in place.
    Phase 3: workload App Services discovered as entities.
    Phase 4: each SLI mapped to an entity from its sli label (healthmodel-entity-map.csv).
    Phase 5: one AMW PromQL signal per SLI attached, Degraded/Unhealthy alerts enabled.
    Phase 6: entity health states read and the root rolls up the workload.
    Mapped SLIs: CheckoutAvailabilitySLI, LoginLatencySLI, PaymentDependencySLI
    Operate and iterate: the health model is the state-based view over the SLIs; review alongside the SLO review.

==> Cleanup (optional)
    This DELETES health model 'hm-test1' and its Monitoring Reader role (the SLI demo is left intact).
Delete health model 'hm-test1' now? (y/N): n
    Left in place. Delete later with:
      ./teardown.ps1 -ResourceGroup rg-hm-test1 -HealthModelName hm-test1
      ./teardown.ps1 -ResourceGroup rg-hm-test1 -HealthModelName hm-test1 -DeleteResourceGroup   # also delete the resource group

    Lab run complete.
```

### If Phase 3 shows only the parent + root entities

Discovery runs on a fixed 5-minute cycle. Right after Phase 2 creates (or reconciles) the model, the App  
Service entities may not be imported yet, so Phase 3 lists only `Checkout/Login workload` (the discovery  
rule parent) and the model root. Wait 5 to 10 minutes and re-run Phase 3 (`-StartPhase 3 -EndPhase 3`).  
If entities still do not appear, confirm the model identity holds **Monitoring Reader** on the SLI  
resource group (Phase 2 self-heals this automatically when it detects the role is missing).

### If signals read "Unknown" in Phase 6

Signals evaluate every minute and read the SLI `:value` series. With no live traffic they report  
"Unknown". Start the traffic generator (Step 2), give it a few minutes, and re-run Phase 6  
(`-StartPhase 6 -EndPhase 6`).

---

## Path B: Run the build by hand (command-by-command)

Path A automates everything below. Run these commands yourself to understand each step, or to adapt the
build to your own app. Every command mirrors what the runner and the two `src/` scripts do
([src/healthmodel-deploy.ps1](src/healthmodel-deploy.ps1), [src/configure-signals-alerts.ps1](src/configure-signals-alerts.ps1)).

### Lab conventions

| Placeholder | Demo value |
| --- | --- |
| `<sli-rg>` | `rg-sli-demo` (SLI app, App Insights, Azure Monitor Workspace) |
| `<hm-rg>` / `<hm>` / `<region>` | `rg-healthmodel-demo` / `hm-checkout-demo` / `centralus` |
| `<amw>` / `<ai>` | `slidemo-amw-ioarvugvrpkmc` / `slidemo-ai-ioarvugvrpkmc` |
| `<sg>` / `<sg-lower>` | `CheckoutSG-ioarvugvrpkmc` / `checkoutsg-ioarvugvrpkmc` |
| `<fe>` / `<be>` | `slidemo-fe-<suffix>` / `slidemo-be-<suffix>` |

Fixed values: health-models API `2026-05-01-preview`; Service Group SLIs API `2025-03-01-preview`; auth
setting `system-assigned`; two discovery-rule names `resource-graph` and `appinsights-topology`.
`Microsoft.CloudHealth` is region-limited (keep `centralus`).

### Phase 1: Environment setup and access checks

**Goal:** confirm the SLI resources exist and their SLI `:value` series carry recent data.

```
az account set --subscription "<your-subscription-name-or-id>"
az group exists -n rg-sli-demo                                   # must print: true

# resources the health model reads
az resource list -g rg-sli-demo --resource-type Microsoft.Insights/components --query "[].name" -o tsv   # <ai>
az resource list -g rg-sli-demo --resource-type Microsoft.Monitor/accounts   --query "[].name" -o tsv   # <amw>

# Service Group that owns the SLIs (tenant-scoped)
$SG = az deployment group show -g rg-sli-demo -n main --query "properties.outputs.suggestedServiceGroupName.value" -o tsv

# Prometheus endpoint + a reusable helper, then read the latest SLI values
$amwId = az resource show -g rg-sli-demo -n slidemo-amw-ioarvugvrpkmc --resource-type Microsoft.Monitor/accounts --query id -o tsv
$PROM  = az resource show --ids $amwId --query "properties.metrics.prometheusQueryEndpoint" -o tsv
function Invoke-Prom($q){ $t=az account get-access-token --resource "https://prometheus.monitor.azure.com" --query accessToken -o tsv; (Invoke-RestMethod -Method Post -Uri "$PROM/api/v1/query" -Headers @{Authorization="Bearer $t"} -Body @{query=$q}).data.result }
foreach ($s in 'checkoutavailabilitysli','loginlatencysli','paymentdependencysli') {
  "$s = " + (Invoke-Prom "last_over_time({__name__=`"ns::checkoutsg-ioarvugvrpkmc/m::${s}:value`"}[1h])").value[1]
}
```

Expected output (with traffic flowing):

```
group exists: true
slidemo-ai-ioarvugvrpkmc
slidemo-amw-ioarvugvrpkmc
checkoutavailabilitysli = 99.82
loginlatencysli = 100
paymentdependencysli = 99.82
```

If no values return, author the SLIs and start traffic (Phase 0), wait a few minutes, and retry.

### Phase 2: Create the health model

**Goal:** create the model + system identity, grant it read access, and create **two** discovery nodes
(Azure Resource Graph and Application Insights topology), each linked to the model root.

```
# 2.1 model + system-assigned identity
$hm  = az monitor health-models create -g rg-healthmodel-demo -n hm-checkout-demo -l centralus --system-assigned -o json | ConvertFrom-Json
$hmId = $hm.id; $pid = $hm.identity.principalId

# 2.2 Monitoring Reader on the SLI RG (discovery reads resource metadata + App Insights)
$sliRgId = az group show -n rg-sli-demo --query id -o tsv
az role assignment create --assignee-object-id $pid --assignee-principal-type ServicePrincipal --role "Monitoring Reader" --scope $sliRgId

# 2.3 authentication setting (system-assigned managed identity)
az rest --method put --url "https://management.azure.com$hmId/authenticationsettings/system-assigned?api-version=2026-05-01-preview" `
  --headers "Content-Type=application/json" `
  --body '{ "properties": { "authenticationKind": "ManagedIdentity", "managedIdentityName": "SystemAssigned", "displayName": "System-assigned managed identity" } }'
```

Create the **two** discovery rules (each auto-creates a parent node named after the rule):

```
# 2.4a Azure Resource Graph node (App Services + plan; recommended signals OFF)
#   PUT .../discoveryrules/resource-graph
#   properties.specification.kind = ResourceGraphQuery
#   resourceGraphQuery = "resources | where resourceGroup =~ 'rg-sli-demo' | where type in~ ('microsoft.web/sites','microsoft.web/serverfarms')"
#   discoverRelationships = Enabled, addRecommendedSignals = Disabled, addResourceHealthSignal = Disabled

# 2.4b Application Insights topology node (cloud-role components + dependencies; recommended signals ON)
$aiId = az resource list -g rg-sli-demo --resource-type Microsoft.Insights/components --query "[0].id" -o tsv
#   PUT .../discoveryrules/appinsights-topology
#   properties.specification.kind = ApplicationInsightsTopology, applicationInsightsResourceId = $aiId
#   discoverRelationships = Enabled, addRecommendedSignals = Enabled
```

The full ARM bodies are in [src/healthmodel-deploy.ps1](src/healthmodel-deploy.ps1). Then link the model
root to each node so health rolls up:

```
az rest --method put --url "https://management.azure.com$hmId/relationships/root-to-resource-graph?api-version=2026-05-01-preview" `
  --headers "Content-Type=application/json" --body '{ "properties": { "parentEntityName": "hm-checkout-demo", "childEntityName": "resource-graph" } }'
az rest --method put --url "https://management.azure.com$hmId/relationships/root-to-appinsights-topology?api-version=2026-05-01-preview" `
  --headers "Content-Type=application/json" --body '{ "properties": { "parentEntityName": "hm-checkout-demo", "childEntityName": "appinsights-topology" } }'
```

Or just run the script (interactive by default; add `-NonInteractive` to skip prompts):

```
./src/healthmodel-deploy.ps1
```

Expected output (the manual PUTs and the script produce the same result):

```
    Monitoring Reader assigned
    authentication setting created
    Resource Graph discovery rule created
    App Insights topology discovery rule created
    root -> Resource Graph node created
    root -> App Insights node created

==> Done. Health model deployed.
Health model:     hm-checkout-demo (rg-healthmodel-demo / centralus)
Discovers:        Two nodes in 'rg-sli-demo': Azure Resource Graph (App Services + plan) and Application Insights topology
```

### Phase 3: Discover the app as entities

**Goal:** verify the App Services were imported under **both** nodes (discovery runs every 5 minutes).

```
az monitor health-models entity list -g rg-healthmodel-demo --health-model-name hm-checkout-demo --query "[].{name:name, display:properties.displayName}" -o table
```

Expected output (both nodes populated after ~5 minutes):

```
Name                                  Display
------------------------------------  --------------------------------------------
0becdb58-...                          slidemo-otelcolapp-ioarvugvrpkmc
47c0f3dc-...                          slidemo-promproxy-ioarvugvrpkmc
526a527a-...                          slidemo-be-ioarvugvrpkmc-plan
7f3883ff-...                          sli-demo-backend
ac0e57fe-...                          slidemo-be-ioarvugvrpkmc
appinsights-topology                  Discovered via Application Insights topology
b847a37f-...                          slidemo-promproxy-ioarvugvrpkmc
ef3b2b3e-...                          slidemo-fe-ioarvugvrpkmc
f7731932-...                          sli-demo-frontend
hm-checkout-demo                      hm-checkout-demo
resource-graph                        Discovered via Azure Resource Graph
```

The Resource Graph node names entities after the ARM resources (`slidemo-fe-*`, `slidemo-be-*`); the App
Insights node names them after the cloud roles (`sli-demo-frontend`, `sli-demo-backend`). If only the two
parent nodes and the model root appear, discovery has not cycled yet, or the identity is missing
Monitoring Reader on `rg-sli-demo`. Wait 5 to 10 minutes and re-list.

### Phase 4: Map the SLIs to entities

**Goal:** for each SLI, read its service/dependency label, confirm its `:value` series, and map it to the
App Service entity that serves it.

```
# 4.1 enumerate the SLIs authored on the Service Group (control plane)
az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/serviceGroups/CheckoutSG-ioarvugvrpkmc/providers/Microsoft.Monitor/slis?api-version=2025-03-01-preview" --query "value[].name" -o tsv

# 4.2 read one SLI's good/total query for its service= / dependency= label
az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/serviceGroups/CheckoutSG-ioarvugvrpkmc/providers/Microsoft.Monitor/slis/CheckoutAvailabilitySLI?api-version=2025-03-01-preview"
# CheckoutAvailabilitySLI -> service=checkout    -> backend (Checkout)
# LoginLatencySLI         -> service=login       -> frontend (Login)
# PaymentDependencySLI    -> dependency=payment  -> backend (Checkout depends on payment)

# 4.3 resolve the frontend/backend entities across BOTH nodes (names differ per node)
$ents = az monitor health-models entity list -g rg-healthmodel-demo --health-model-name hm-checkout-demo -o json | ConvertFrom-Json
$fe = $ents | Where-Object { ($_.properties.displayName -like '*-fe-*' -or $_.properties.displayName -like '*frontend*') -and $_.properties.displayName -notlike '*-plan' }
$be = $ents | Where-Object { ($_.properties.displayName -like '*-be-*' -or $_.properties.displayName -like '*backend*')  -and $_.properties.displayName -notlike '*-plan' }
$fe.properties.displayName; $be.properties.displayName
```

Expected output:

```
# 4.1 authored SLIs
CheckoutAvailabilitySLI
LoginLatencySLI
PaymentDependencySLI

# 4.3 frontend then backend (each appears once per discovery node)
slidemo-fe-ioarvugvrpkmc
sli-demo-frontend
sli-demo-backend
slidemo-be-ioarvugvrpkmc
```

Mapping rule: services in the frontend list (`login`) map to the frontend App Service; every other
service or dependency (`checkout`, `payment`) maps to the backend. The runner records the result to
`healthmodel-entity-map.csv`.

### Phase 5: Configure signals and alerts

**Goal:** grant AMW data-plane read, attach one PromQL SLI signal per SLI to the app entities in **both**
nodes, give the supporting resources an uptime signal, and roll up to the root.

```
$hmId  = az monitor health-models show -g rg-healthmodel-demo -n hm-checkout-demo --query id -o tsv
$pid   = az monitor health-models show -g rg-healthmodel-demo -n hm-checkout-demo --query identity.principalId -o tsv
$amwId = az resource list -g rg-sli-demo --resource-type Microsoft.Monitor/accounts --query "[0].id" -o tsv

# 5.1 AMW query roles: Monitoring Data Reader (data plane, REQUIRED) + Monitoring Reader
foreach ($r in 'Monitoring Data Reader','Monitoring Reader') {
  az role assignment create --assignee-object-id $pid --assignee-principal-type ServicePrincipal --role $r --scope $amwId
}
```

For each frontend/backend entity in **both** nodes, PUT an `azureMonitorWorkspace` signal group. Backend
(Checkout) carries the Checkout availability + Payment dependency SLIs; frontend (Login) carries the Login
latency SLI. Each signal is a `PrometheusMetricsQuery` reading
`last_over_time({__name__="ns::<sg-lower>/m::<sli-lower>:value"}[1h])`, with thresholds Degraded `< 99` /
Unhealthy `< 95` and Sev2/Sev1 alerts. App Service entities also get a tuned `Http5xx` signal (Degraded
`> 30`, Unhealthy `> 150`) so normal 5xx noise stays green. Supporting resources get Resource Health
(Basic+ plans) or a platform uptime signal (Free/Shared); resource types that support neither have their
signals cleared. The full ARM bodies are in
[src/configure-signals-alerts.ps1](src/configure-signals-alerts.ps1).

> **Pin the Service Group.** One AMW can hold the same SLI names under several `ns::<sg>/...` namespaces
> (from other tests). Pass `-ServiceGroup CheckoutSG-ioarvugvrpkmc` so the signals reference the right
> namespace; otherwise a signal may bind a stale/empty series and read Unknown with "Result array is
> empty".

Then link the root to each discovery node (the deploy already did this; the configure script re-applies
it). Or just run the script:

```
./src/configure-signals-alerts.ps1 -ServiceGroup CheckoutSG-ioarvugvrpkmc
```

Expected output (signals attached to the app entities in both nodes):

```
==> Ensuring AMW query roles (Monitoring Data Reader + Monitoring Reader) for the health model identity
    Monitoring Data Reader assigned
    Monitoring Reader assigned
==> Discovering published SLI result series in the AMW
    CheckoutAvailabilitySLI: found
    LoginLatencySLI: found
    PaymentDependencySLI: found
==> Checkout (backend): sli-demo-backend = 'sli-demo-backend': Checkout availability SLI (AMW), Payment dependency SLI (AMW)
==> Checkout (backend): slidemo-be-ioarvugvrpkmc = 'slidemo-be-ioarvugvrpkmc': Checkout availability SLI (AMW), Payment dependency SLI (AMW)
==> Login (frontend): slidemo-fe-ioarvugvrpkmc = 'slidemo-fe-ioarvugvrpkmc': Login latency SLI (AMW)
==> Login (frontend): sli-demo-frontend = 'sli-demo-frontend': Login latency SLI (AMW)
==> App Service plan tier: Free (Resource Health supported: False)
==> Uptime signal (Uptime (HTTP 2xx)) on 'slidemo-otelcolapp-ioarvugvrpkmc'
==> Uptime signal (CPU % (App Service plan)) on 'slidemo-be-ioarvugvrpkmc-plan'
==> Linking the model root to each discovery node so health rolls up
    root -> appinsights-topology updated
    root -> resource-graph updated

==> Done. AMW signals and alerts configured.
```

### Phase 6: Validate end-to-end

**Goal:** confirm each app entity carries its SLI signal(s) and reads a real value, and that the root
rolls up **both** nodes.

```
# 6.1 entity health + attached SLI signals
az monitor health-models entity list -g rg-healthmodel-demo --health-model-name hm-checkout-demo -o json |
  ConvertFrom-Json | ForEach-Object {
    [pscustomobject]@{ Entity=$_.properties.displayName; Health=$_.properties.healthState;
      SliSignals=($_.properties.signalGroups.azureMonitorWorkspace.signals.displayName -join ', ') } } |
  Format-Table -AutoSize

# 6.2 confirm the stored :value series (should match the SLI portal values)
foreach ($s in 'checkoutavailabilitysli','loginlatencysli','paymentdependencysli') {
  "$s = " + (Invoke-Prom "last_over_time({__name__=`"ns::checkoutsg-ioarvugvrpkmc/m::${s}:value`"}[1h])").value[1]
}

# 6.3 confirm the root links to BOTH discovery nodes
az rest --method get --url "https://management.azure.com$hmId/relationships?api-version=2026-05-01-preview" `
  --query "value[?properties.parentEntityName=='hm-checkout-demo'].properties.childEntityName" -o tsv
# expected: resource-graph  and  appinsights-topology
```

Expected output (all app entities Healthy with their SLI signals; root rolls up both nodes):

```
-- 6.1 entity health + attached SLI signals --
Entity                                     Health  SliSignals
------                                     ------  ----------
slidemo-otelcolapp-ioarvugvrpkmc           Healthy
slidemo-promproxy-ioarvugvrpkmc            Healthy
slidemo-be-ioarvugvrpkmc-plan              Healthy
sli-demo-backend                           Healthy Checkout availability SLI (AMW), Payment dependency SLI (AMW)
slidemo-be-ioarvugvrpkmc                   Healthy Checkout availability SLI (AMW), Payment dependency SLI (AMW)
Workload via Application Insights topology Healthy
slidemo-fe-ioarvugvrpkmc                   Healthy Login latency SLI (AMW)
sli-demo-frontend                          Healthy Login latency SLI (AMW)
hm-checkout-demo                           Healthy
Workload via Azure Resource Graph          Healthy

-- 6.2 stored :value series --
checkoutavailabilitysli = 99.82
loginlatencysli = 100
paymentdependencysli = 99.82

-- 6.3 root links to both discovery nodes --
appinsights-topology
resource-graph
```

If a signal reads Unknown with "Signal error", see the two causes in
[Troubleshooting](#troubleshooting): a missing Monitoring Data Reader role, or the wrong service-group
namespace.

---

## Outputs

| File | Written in | Contents |
| --- | --- | --- |
| `healthmodel-entity-map.csv` | Phase 4 | One row per SLI: derived sli label, role (frontend/backend), mapped entity, stored value, and whether the `:value` series was found. |

---

## Example run output

The two write steps can also be run directly (the lab runner invokes the same scripts in Phase 2 and Phase 5). A clean run looks like this, with CLI preview warnings trimmed and long resource IDs shortened.

### src/healthmodel-deploy.ps1 (Phase 2)

Interactive by default: press Enter to accept each `[default]`, or add `-NonInteractive` to skip the prompts.

```
PS ...\02-healthmodel-demo> ./src/healthmodel-deploy.ps1
==> Subscription: ME-MngEnvMCAP993834-varghesejoji-1 (463a82d4-...)
==> Interactive setup (press Enter to accept each [default]; run with -NonInteractive to skip)
    Health model name [hm-checkout-demo]:
    Health model resource group [rg-healthmodel-demo]:
    Health model region [centralus]:
    SLI resource group (source workload) [rg-sli-demo]:
==> Ensuring the health-models CLI extension is installed
==> Verifying SLI resource group rg-sli-demo
==> Ensuring resource group rg-healthmodel-demo
    already exists in 'eastus2' (reusing; health model region is set separately)
==> Registering resource provider Microsoft.CloudHealth
==> Creating health model hm-checkout-demo with a system-assigned identity
    Health model id: /subscriptions/.../healthmodels/hm-checkout-demo
    System identity principalId: d801a45e-7809-4c09-9ece-18a860e20276
==> Granting Monitoring Reader on rg-sli-demo to the health model identity
    Monitoring Reader assigned
==> Creating authentication setting (system-assigned managed identity)
    authentication setting created
==> Creating Azure Resource Graph discovery rule (App Services + plan)
    Resource Graph discovery rule created
==> Creating Application Insights topology discovery rule (recommended signals enabled)
    App Insights topology discovery rule created
==> Linking the model root to each discovery node (health roll-up)
    root -> Resource Graph node created
    root -> App Insights node created

==> Done. Health model deployed.
Health model:     hm-checkout-demo (rg-healthmodel-demo / centralus)
Discovers:        Two nodes in 'rg-sli-demo': Azure Resource Graph (App Services + plan) and Application Insights topology
Portal:           https://portal.azure.com/#@.../hm-checkout-demo/overview
```

Give discovery ~5 to 10 minutes to populate the two nodes before running the next step.

### src/configure-signals-alerts.ps1 (Phase 5)

Attaches the AMW PromQL SLI signals + alerts to the app entities in both nodes, a tuned Http5xx to the App Services, Resource Health to the supporting resources, clears signals on resource types that do not support one (for example the App Insights failure-anomalies alert rule), and links the root to both nodes. The backend and frontend appear under both discovery nodes, so each is configured once per node.

```
PS ...\02-healthmodel-demo> ./src/configure-signals-alerts.ps1
==> Locating Azure Monitor Workspace in rg-sli-demo
    AMW: /subscriptions/.../Microsoft.Monitor/accounts/slidemo-amw-ioarvugvrpkmc
==> Ensuring AMW query roles (Monitoring Data Reader + Monitoring Reader) for the health model identity
    Monitoring Data Reader assigned
    Monitoring Reader assigned
==> Discovering published SLI result series in the AMW
    CheckoutAvailabilitySLI: found
    LoginLatencySLI: found
    PaymentDependencySLI: found
==> Checkout (backend): slidemo-be-ioarvugvrpkmc: Checkout availability SLI (AMW), Payment dependency SLI (AMW)
==> Checkout (backend): sli-demo-backend: Checkout availability SLI (AMW), Payment dependency SLI (AMW)
==> Login (frontend): slidemo-fe-ioarvugvrpkmc: Login latency SLI (AMW)
==> Login (frontend): sli-demo-frontend: Login latency SLI (AMW)
==> App Service plan tier: PremiumV3 (Resource Health supported: True)
==> Uptime signal (Resource Health) on 'slidemo-otelcolapp-ioarvugvrpkmc'
==> Clearing signals on 'failure anomalies - slidemo-ai-ioarvugvrpkmc' (resource type does not support an uptime signal)
==> Uptime signal (Resource Health) on 'slidemo-be-ioarvugvrpkmc-plan'
==> Uptime signal (Resource Health) on 'slidemo-promproxy-ioarvugvrpkmc'
==> Linking the model root to each discovery node so health rolls up
    root -> appinsights-topology updated
    root -> resource-graph updated

==> Done. AMW signals and alerts configured.
```

Signals read **Unknown** until the SLI metrics have data, so keep the traffic generator running (Step 2).

---

## Troubleshooting

*   **Phase 1.5 reports the SLI series have no recent data / run stalls**: the traffic generator is not  
    running or has not registered yet. Start Step 2 in a separate terminal, wait 1 to 2 minutes, then  
    re-run the lab.
*   **Phase 3 shows only 2 entities (parent + root)**: discovery has not cycled yet, or the identity lost  
    Monitoring Reader on the SLI resource group. Re-run Phase 2 (it self-heals the role) and allow 5 to 10  
    minutes, then re-run Phase 3.
*   **Phase 4 shows an entity as "(not discovered)"**: the App Service entities are not imported yet (see  
    above) or the `-FrontendLike` / `-BackendLike` patterns do not match your entity display names. Adjust  
    the patterns to match the discovered names.
*   **Phase 6 signals read "Unknown"**: expected without live traffic. Start the generator and re-run  
    Phase 6 after a few evaluation cycles.
*   **Signals read "Unknown" with "Signal error" even though the SLIs publish fine**: two common causes.  
    (1) The identity lacks **Monitoring Data Reader** on the Azure Monitor Workspace (the data-plane role  
    PromQL signals need to query); the current `src/configure-signals-alerts.ps1` grants it. (2) The signal  
    references the wrong service-group namespace ("Result array is empty"): one AMW can hold the same SLI  
    names under several `ns::<sg>/...` namespaces, so pass `-ServiceGroup <your-sg>` (the runner does this  
    automatically) and re-run Phase 5.
*   **Phase 2 skipped** `**src/healthmodel-deploy.ps1**` **for an existing model under** `**-NonInteractive**`: expected when the model  
    exists and the identity already holds Monitoring Reader. If the role is missing, Phase 2 re-runs  
    `src/healthmodel-deploy.ps1` automatically.

---

## How this maps to the Azure docs

| Doc step | Automated by |
| --- | --- |
| **Create > Basics** (subscription, resource group, region, name) | `az group create` + `az monitor health-models create -g -n -l` |
| **Create > Identity** (system-assigned managed identity) | `--system-assigned` on the create command |
| **Create > Permissions** (Monitoring Reader on monitored resources) | `az role assignment create --role "Monitoring Reader"` on the SLI RG |
| **Discoveries > authentication setting** | `az rest PUT .../authenticationsettings/system-assigned` (ManagedIdentity) |
| **Discoveries > Resource Graph query** | `az rest PUT .../discoveryrules/resource-graph` (specification kind `ResourceGraphQuery`, App Services + plan) |
| **Discoveries > Application Insights topology** | `az rest PUT .../discoveryrules/appinsights-topology` (specification kind `ApplicationInsightsTopology`, recommended signals enabled) |

The child resources are created with `az rest` (explicit ARM bodies) at API version `2026-05-01-preview` so the exact discovery configuration is deterministic; the model itself uses the first-class `az monitor health-models` commands.

---

## Portal fallback (if the preview CLI/API changes)

If a preview API change breaks `src/healthmodel-deploy.ps1`, reproduce the same result in the portal:

1.  **Health models > Create.** Basics: pick your subscription, `rg-healthmodel-demo`, a supported region such as `centralus`, name `hm-checkout-demo`. Identity: enable **system-assigned**. Create.
2.  Assign **Monitoring Reader** to the health model's system-assigned identity on `rg-sli-demo` (Access control (IAM) on the resource group).
3.  Open the health model > **Discovery** > **Create**. Create two rules: (a) **Resource Graph query** with `resources | where resourceGroup =~ 'rg-sli-demo' | where type in~ ('microsoft.web/sites','microsoft.web/serverfarms')`, **Discover relationships** on, **Add recommended signals** off; and (b) **Application Insights topology** pointed at the SLI demo's Application Insights, **Discover relationships** on, **Add recommended signals** on.
4.  Wait ~5 minutes and open the **Graph view**.

---

## Related files

*   [healthmodel-run-lab.ps1](healthmodel-run-lab.ps1): the lab runner.
*   [src/healthmodel-deploy.ps1](src/healthmodel-deploy.ps1): creates the health model, identity, role, authentication setting, and  
    two discovery rules, Azure Resource Graph and Application Insights topology (Phase 2).
*   [src/configure-signals-alerts.ps1](src/configure-signals-alerts.ps1): attaches SLI signals and alerts and links  
    the root to each discovery node; signals are attached to the app entities in both nodes (Phase 5).
*   [teardown.ps1](teardown.ps1): deletes the health model and its role assignment.
*   [Health-Model-Design-Guide.md](Health-Model-Design-Guide.md): the concepts behind the method.
*   [../01-sli-demo/sli-run-lab.ps1](../01-sli-demo/sli-run-lab.ps1): the SLI lab that authors the SLIs this model reads.
*   [../01-sli-demo/load/generate-traffic-all.ps1](../01-sli-demo/load/generate-traffic-all.ps1): the manual  
    traffic generator (Step 2).