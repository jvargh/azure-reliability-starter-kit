# SRE Agent Lab: User Guide

A guided walkthrough for wiring the **Azure SRE Agent** to auto-remediate the Checkout/Login workload
when it enters a **Degraded** or **Unhealthy** state. This is Phase 2 of the reliability kit and builds
directly on the SLI demo ([../01-sli-demo](../01-sli-demo)) and the Health Model demo
([../02-healthmodel-demo](../02-healthmodel-demo)).

This phase is **SRE Agent only** (no Observability Agent, no Azure Monitor Issues). The trigger is the
Azure Monitor alerts you already emit: SLI burn-rate/baseline alerts and Health Model health-state
alerts.

> The agent deploys **as code**. `sre-run-lab.ps1` provisions it via the official IaC templates
> (`Microsoft.App/agents`, the `azmon-lawappinsights` recipe): the managed identity, Log Analytics,
> App Insights, RBAC on the managed resource groups, and the incident response plan are all created for
> you. It also uploads the app topology and every remediation runbook to the agent's Knowledge settings
> (Phase 6.6). The only remaining portal steps are the interactive OAuth connections that cannot be
> scripted (GitHub sign-in, and confirming the Azure Monitor Alerts incident source). Once deployed, run
> `sli-alert-scenario.ps1` to enable a fast SLI alert, inject a fault, and watch the agent engage and
> remediate. A manual portal-wizard fallback is included at the end for preview environments where the
> templates are unavailable.

---

## Table of contents

- [What this lab does](#what-this-lab-does)
- [State to response mapping](#state-to-response-mapping)
- [Prerequisites](#prerequisites)
- [Deploy the SRE Agent (automated)](#deploy-the-sre-agent-automated)
- [Knowledge and runbooks uploaded to the agent](#knowledge-and-runbooks-uploaded-to-the-agent)
- [Trigger the agent: enable the SLI alert and remediate](#trigger-the-agent-enable-the-sli-alert-and-remediate)
- [Troubleshooting](#troubleshooting)
- [Related files](#related-files)

---

## What this lab does

| Step | Action | How |
| --- | --- | --- |
| 1 | Deploy the SRE Agent as code in East US 2, scoped to the two demo RGs, approval-only, with its response plan | `sre-run-lab.ps1` |
| 2 | Upload the app topology + all remediation runbooks to the agent's Knowledge settings | `sre-run-lab.ps1` Phase 6.6 (`upload-knowledge.ps1`) |
| 3 | Connect GitHub + confirm the Azure Monitor Alerts incident source (interactive OAuth) | portal, one-time |
| 4 | Demo: enable the fast SLI alert, inject a fault, let the agent engage and remediate | `sli-alert-scenario.ps1` |

---

## State to response mapping

| State / signal | Source | Severity | SRE Agent response |
| --- | --- | --- | --- |
| SLI fast burn (~14x / 1h) | SLI burn-rate alert | Sev1 | Page + investigate immediately |
| Health Model Unhealthy (SLI `< 95`) | health-state alert | Sev1 | Investigate + **execute** an approved remediation |
| Health Model Degraded (SLI `< 99`) | health-state alert | Sev2 | Investigate + **propose** only |
| SLI slow burn (~3x / 6h) | SLI burn-rate alert | Sev2 | Ticket + weekly review |

The full agent instructions are in [src/incident-response-plan.md](src/incident-response-plan.md).

---

## Prerequisites

1. SLI demo deployed + SLIs authored ([../01-sli-demo](../01-sli-demo)), with traffic running.
2. Health Model deployed with health-state alerts ([../02-healthmodel-demo](../02-healthmodel-demo)).
3. Azure CLI signed in; **Owner** or **User Access Administrator** on the subscription (needed to grant
   the agent's managed identity its RBAC).
4. `*.azuresre.ai` allowed through your firewall.
5. SRE Agent region: **East US 2** (this lab). The workload can stay in its own region.

---

## Deploy the SRE Agent (automated)

`sre-run-lab.ps1` provisions the agent end to end via the official IaC templates. It runs in six phases:
resolve the environment and register `Microsoft.App` (1), acquire the templates (2), generate the agent
config from the `azmon-lawappinsights` recipe (3), deploy `Microsoft.App/agents` plus its managed
identity, Log Analytics, App Insights, and RBAC on `rg-sli-demo` + `rg-healthmodel-demo` (4), confirm the
provisioning state is `Succeeded` (5), and wire inputs: apply the incident response plan, verify the
alert inputs, and upload the knowledge base (6). Step **6.6** uploads the app topology and every
remediation runbook to the agent's Knowledge settings.

```powershell
cd 03-sre-agent
./sre-run-lab.ps1 -SkipRepos                      # interactive (skips optional GitHub setup)
# ./sre-run-lab.ps1 -SkipRepos -NonInteractive   # unattended
# ./sre-run-lab.ps1 -SkipRepos -DryRun           # what-if, no changes
```

`-SkipRepos` skips the optional GitHub connection (used only for deploy/commit correlation), so the run
never pauses for a browser OAuth sign-in. Connect GitHub later in `sre.azure.com > Repos` if you want it,
or drop the flag to be prompted during the run.

This creates the agent in **East US 2**, scoped to the two demo resource groups, in **Reader /
approval-only** mode, and applies [src/incident-response-plan.md](src/incident-response-plan.md) as the
response plan. No portal wizard is required.

**Choosing an agent (Phase 1.5).** An interactive run lists any existing SRE Agents in the subscription
and lets you pick one to reuse (by number) or press `n` to create a new one (prompting for name,
resource group, and region). Selecting "create new" produces a fully independent agent; Phase 3
regenerates its config from scratch, so nothing from a prior agent is carried over.

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Subscription` | current | Optional subscription to select first. |
| `-AgentName` | `sre-checkout` | SRE Agent resource name. |
| `-ResourceGroup` | `rg-sre-agent` | Resource group for the agent (created if missing). |
| `-Location` | `eastus2` | Agent region: `swedencentral`, `eastus2`, or `australiaeast`. |
| `-Recipe` | `azmon-lawappinsights` | SRE Agent IaC recipe (Azure Monitor + Log Analytics + App Insights). |
| `-SliResourceGroup` | `rg-sli-demo` | SLI demo RG; becomes a managed/target RG the agent ingests alerts from. |
| `-HealthModelResourceGroup` | `rg-healthmodel-demo` | Health Model RG; the second managed/target RG. |
| `-ActionGroupName` | `ag-sli-demo` | Action group used by the SLI/Health Model alerts (created in Phase 6 if missing). |
| `-TemplatesRepo` | `github.com/microsoft/sre-agent` | Official SRE Agent IaC templates repo (cloned in Phase 2). |
| `-TemplatesPath` | none | Point at an existing templates clone to skip cloning. |
| `-DryRun` | off | Pass Bicep what-if to Deploy-Agent (validate, do not deploy). |
| `-SkipPrereqs` | off | Skip the templates' `Install-Prerequisites.ps1` (jq, Python + PyYAML). |
| `-SkipRepos` | off | Strip the placeholder GitHub repo so the deploy never waits on GitHub OAuth. |
| `-ShowBicepWarnings` | off | Show the upstream templates' Bicep linter/compiler warnings (suppressed by default). |
| `-StartPhase` / `-EndPhase` | `1` / `6` | Run a subset of the phases (Phase 1 setup always runs first). |
| `-NonInteractive` | off | Accept every default without prompting. |

Phases: 1 Environment + access checks, 2 Acquire the IaC templates, 3 Generate the agent config from the
recipe, 4 Deploy the agent, 5 Validate the agent is up, 6 Wire inputs (alerts + response plans + knowledge upload).

### Examples

```powershell
# Full interactive run (lists existing agents; pick one or create new)
./sre-run-lab.ps1 -SkipRepos

# Unattended run with defaults
./sre-run-lab.ps1 -SkipRepos -NonInteractive

# Validate only (Bicep what-if; no resources changed)
./sre-run-lab.ps1 -DryRun

# Skip the optional GitHub OAuth wiring
./sre-run-lab.ps1 -SkipRepos

# Target a specific subscription, name, resource group, and region
./sre-run-lab.ps1 -Subscription 463a82d4-... -AgentName sre-checkout -ResourceGroup rg-sre-agent -Location eastus2

# Re-apply the response plan and re-verify only (after a deploy)
./sre-run-lab.ps1 -StartPhase 6 -EndPhase 6

# Point at an existing templates clone (skip cloning)
./sre-run-lab.ps1 -TemplatesPath C:\path\to\sre-agent

# Show the upstream Bicep template warnings during deploy
./sre-run-lab.ps1 -ShowBicepWarnings
```

### What matters in a run

- **The run ends green.** The authoritative check is the **Phase 6.5** verification table (`22 passed, 0 failed`). The earlier phases are progress; 6.5 is the final state.
- **The agent deploys as code** (`Microsoft.App/agents`) in ~2 to 3 minutes: managed identity, Log Analytics, App Insights, and RBAC on both target resource groups.
- **Incident platform = `AzMonitor`** is the key wiring. That is how the agent ingests the SLI burn-rate and Health Model health-state alerts.
- **Response plan `azmon-sev01` is applied** (Sev0/Sev1 → `alert-investigator`, Autonomous). The deploy's first attempt can fail while the incident platform is still initializing; Phase 6.4 retries until it sticks, and 6.5 confirms it.
- **Approval-only:** Access level `Low`, Action mode `Review`. The agent proposes and never acts without your sign-off.
- **Knowledge uploaded (Phase 6.6).** The app topology doc and every `src/remediation-runbooks/*.ps1` are uploaded to the agent's Knowledge settings, so it knows the layout and mitigations from the first incident.
- **The metric alerts listed in Phase 6.1 are the SLI demo's linked alerts (display-only).** The SLI demo authors 9 metric alert rules on `rg-sli-demo` (baseline/fast/slow burn per SLI); they surface on the SLI blade but do not fire, and `rg-healthmodel-demo` shows none. Drive a real, firing trigger with `./sli-alert-scenario.ps1`.

### Full run output (clean run)

```
> ./sre-run-lab.ps1 -SkipRepos

SRE Agent Lab - interactive runner
Phases 1 to 6

==============================================================================
  PHASE 1: Environment and access checks
==============================================================================
==> 1.1 - Subscription
    Subscription : ME-MngEnvMCAP993834-varghesejoji-1 (463a82d4-1896-4332-aeeb-618ee5a5aa93)
==> 1.2 - Register resource provider Microsoft.App (required for the SRE Agent)
    Microsoft.App: Registered
==> 1.3 - Confirm the workload resource groups exist
    rg-sli-demo found.
    rg-healthmodel-demo found.
==> 1.4 - Confirm the trigger alerts the agent will ingest
    rg-sli-demo: 9 metric alert rule(s)
    rg-healthmodel-demo: 0 metric alert rule(s)
    These SLI burn-rate + Health Model health-state alerts are the SRE Agent triggers.
==> 1.5 - Choose the SRE Agent to create or reuse
    The SRE Agent (Microsoft.App/agents) region is limited to swedencentral, eastus2, australiaeast.
    Existing SRE Agents in this subscription (select one to reuse, or create new):
      [0] sre1  (sre1-rg / eastus2)
      [1] sre2-eus2  (sre2-eus2-rg / eastus2)
      [2] sre-lab-01  (sre-lab-01 / eastus2)
      [n] Create a new SRE Agent
Select an agent number to reuse, or n to create new [n]: n
    New SRE Agent (press Enter to accept each default):
Agent name [sre-checkout]:
Agent resource group [rg-sre-agent]: rg-sre-checkout
Agent region (swedencentral/eastus2/australiaeast) [eastus2]:

  Confirmed configuration:

Subscription : 463a82d4-1896-4332-aeeb-618ee5a5aa93
Agent        : sre-checkout
AgentRG      : rg-sre-checkout
Region       : eastus2
AgentState   : new (Phase 4 creates it)
Recipe       : azmon-lawappinsights
TargetRGs    : rg-sli-demo, rg-healthmodel-demo
ActionGroup  : ag-sli-demo

Proceed with these values? (Y/n): y
-- Phase 1 complete. Press Enter to continue:

==============================================================================
  PHASE 2: Acquire the SRE Agent IaC templates
==============================================================================
    Uses the production templates from microsoft/sre-agent (Bicep, PowerShell backend).
==> 2.1 - Updating existing templates clone
    Templates: ...\03-sre-agent\.sre-agent-templates\sreagent-templates
    Quieted Deploy-Agent.ps1 (suppressed raw deployment JSON + redundant inline verification).
==> 2.2 - Installing recipe prerequisites (jq, Python + PyYAML)
═══════════════════════════════════════════════════
  SRE Agent - Prerequisites Check
  OS: Windows (PowerShell 7.6.4)
═══════════════════════════════════════════════════

── PowerShell ──
  ✅ PowerShell 7.6.4

── Required tools ──
  ✅ az CLI {
  ✅ jq jq-1.7.1
  ✅ curl curl 8.21.0 (Windows) libcurl/8.21.0 Schannel zlib/1.3.2 WinIDN WinLDAP
  ✅ Python Python 3.13.14
  ✅ PyYAML

All prerequisites installed! ✅
-- Phase 2 complete. Press Enter to continue:

==============================================================================
  PHASE 3: Generate the agent config from the recipe
==============================================================================
    Recipe 'azmon-lawappinsights' wires Azure Monitor alert response with Log Analytics + App Insights.
Generate config into ...\03-sre-agent\.agent-config\sre-checkout? (Y/n): y
==> 3.1 - New-Agent.ps1
    Removing stale config from a previous run for this agent name (fresh generation).

── Recipe: azmon-lawappinsights ──
General-purpose SRE Agent with AppInsights + Log Analytics connectors, safety defaults, and a daily health check.

  Agent name (lowercase, hyphens ok): sre-checkout (preset)
  Region: eastus2 (preset)
  AI model provider: Anthropic (default)
  Resource group for the agent: rg-sre-checkout (preset)
  Resource groups to monitor (comma-separated): rg-sli-demo,rg-healthmodel-demo (preset)

── Creating agent config: ...\03-sre-agent\.agent-config\sre-checkout/ ──


── Setup complete ──

  ...\03-sre-agent\.agent-config\sre-checkout/
    agent.json               <- Review and adjust if needed
    connectors.json          <- Connector configs
    connectors.secrets.env   <- Secrets (gitignored)
    config/
      skills/                  <- 2 file(s)
      subagents/               <- 2 file(s)
      hooks/                   <- 2 file(s)
      common-prompts/          <- 2 file(s)
      repos/                   <- 1 file(s)
    automations/
      scheduled-tasks/         <- 1 file(s)
      incident-filters/        <- 1 file(s)
      incident-platforms/      <- 1 file(s)

    Cleared expected connectors (not deployed by this lab; keeps the final verification truthful).
    Added common prompt: memory-write-policy (no memory writes + always remediate).
    Config written to ...\.agent-config\sre-checkout
-- Phase 3 complete. Press Enter to continue:

==============================================================================
  PHASE 4: Deploy the agent
==============================================================================
    Deploys the resource group, managed identity, Log Analytics, App Insights, the SRE Agent
    (Microsoft.App/agents), and RBAC on the target resource groups.
Run Deploy-Agent.ps1 now (deploy)? (Y/n): y
    Removed placeholder GitHub repo config (skips OAuth; connect GitHub later in the portal).
==> 4.1 - Deploy-Agent.ps1
    Suppressing upstream Bicep template warnings (pass -ShowBicepWarnings to see them).

── Assembling config/ ──
  skills: 2
  subagents: 2
  hooks: 2
  common-prompts: 3
  scheduled-tasks: 1
  incident-filters: 1
  incident-platforms: 1
  repos: 0
  Found 1 synthesized knowledge file(s) in data/synthesized-knowledge/

──────────────── SRE Agent deployment ────────────────
  Subscription:  ME-MngEnvMCAP993834-varghesejoji-1 (463a82d4-1896-4332-aeeb-618ee5a5aa93)
  Region:        eastus2
  Agent name:    sre-checkout
  Agent RG:      rg-sre-checkout  (will be created)
  Target RGs:    rg-sli-demo, rg-healthmodel-demo
  Access level:  Low
  Action mode:   Review
  Upgrade chan:  Preview
  Model:         Anthropic
  Monthly limit: 10000 AU

  Data-plane (apply-extras):
    ✓ Scheduled tasks: 1
    ✓ Incident filters (response plans): 1
    ✓ Hooks: 2
    ✓ Common prompts: 3
    ✓ Incident platforms: 1

  Deployment name: sre-agent-20260723-222506
─────────────────────────────────────────────────────

Starting deployment (this typically takes 3-5 min)...

─────────────── Deployment Succeeded ───────────────
  Agent (portal):  https://sre.azure.com/#/agent/463a82d4-.../rg-sre-checkout/sre-checkout
  Data plane:      https://sre-checkout--80447abf.6bb75fe4.eastus2.azuresre.ai

── Applying data-plane config (extras) ──
incidentPlatforms: 1
  ARM PATCH -> incidentManagementConfiguration.type=AzMonitor
    ok
  Waiting 30s for platform to initialize...
incidentFilters (response plans): 1
  data-plane PUT incidentFilters/azmon-sev01 - retry 1/4 in 30s (platform init)...
  data-plane PUT incidentFilters/azmon-sev01 - retry 2/4 in 30s (platform init)...
  data-plane PUT incidentFilters/azmon-sev01 - retry 3/4 in 30s (platform init)...
  data-plane PUT incidentFilters/azmon-sev01
    FAILED   (expected during platform init; reconciled in Phase 6.4)
scheduledTasks: 1
  ok scheduledtasks/daily-health-check
synthesizedKnowledge: 1 file(s)
  data-plane POST WorkspaceMemory/synthesized-knowledge (1 files)
    ok
hooks: 2
  ok hooks/deny-prod-deletes
  ok hooks/require-approval-for-restarts
commonPrompts: 3
  ok commonprompts/investigation-guidelines
  ok commonprompts/memory-write-policy
  ok commonprompts/safety-rules
skills: 2
  ok skills/investigate-azure-alerts
  ok skills/triage-app-errors
subagents: 2
  ok agents/alert-investigator
  ok agents/remediation-advisor
Done.

── Setting up UAMI roles (from roles.yaml) ──
  UAMI principal ID: 9acf6fc8-ee23-4898-9d77-e8d5d1a45587

    The post-deploy verification above is the template's own snapshot taken right after deploy.
    The authoritative check runs at the end of Phase 6 (step 6.5), after all config is applied.
-- Phase 4 complete. Press Enter to continue:

==============================================================================
  PHASE 5: Validate the agent is up
==============================================================================
==> 5.1 - Locate the SRE Agent resource
    Agent: sre-checkout
    Provisioning state : Succeeded
    Data plane: https://sre-checkout--80447abf.6bb75fe4.eastus2.azuresre.ai
    Deep data-plane verification runs at the end of Phase 6 (step 6.5).
-- Phase 5 complete. Press Enter to continue:

==============================================================================
  PHASE 6: Wire inputs from Health Model and SLI
==============================================================================
==> 6.1 - Alerts on the target resource groups
    rg-sli-demo: [on] Sev1  CheckoutAvailabilitySLI baseline alert
    rg-sli-demo: [on] Sev2  CheckoutAvailabilitySLI fast burn alert
    rg-sli-demo: [on] Sev3  CheckoutAvailabilitySLI slow burn alert
    rg-sli-demo: [on] Sev2  LoginLatencySLI baseline alert
    rg-sli-demo: [on] Sev2  LoginLatencySLI fast burn alert
    rg-sli-demo: [on] Sev3  LoginLatencySLI slow burn alert
    rg-sli-demo: [on] Sev2  PaymentDependencySLI baseline alert
    rg-sli-demo: [on] Sev2  PaymentDependencySLI fast burn alert
    rg-sli-demo: [on] Sev3  PaymentDependencySLI slow burn alert
    rg-healthmodel-demo: no metric alert rules (author SLI burn alerts / Health Model health-state alerts first).
==> 6.2 - Action Group (human notification path)
    ag-sli-demo present: .../actionGroups/ag-sli-demo
==> 6.3 - Confirm the agent target scope covers both resource groups
    Recipe targetRGs deployed with: rg-sli-demo, rg-healthmodel-demo
==> 6.4 - Apply response plans (incident filters) so alerts are auto-handled
    Retries until the AzMonitor incident platform has initialized (can take a few minutes).
    Response plan applied: azmon-sev01 (priorities Sev0/Sev1 -> alert-investigator)
==> 6.5 - Final data-plane verification (all config applied)

═══════════════════════════════════════════════════════
  SRE Agent Verification: sre-checkout
  Endpoint: https://sre-checkout--80447abf.6bb75fe4.eastus2.azuresre.ai
═══════════════════════════════════════════════════════
  Check                     Actual     Expected   Result
  ───────────────────────── ────────── ────────── ──────
  Agent exists              yes        yes        ✅ PASS
  Access level              Low        Low        ✅ PASS
  Action mode               Review     Review     ✅ PASS
  Upgrade channel           Preview    Preview    ✅ PASS
  Model provider            Anthropic  Anthropic  ✅ PASS
  Incident platform         AzMonitor  AzMonitor  ✅ PASS
  Connectors (total)        0          0          ✅ PASS
  Connectors (healthy)      0          0          ✅ PASS
  Skills                    2          2          ✅ PASS
  Subagents                 2          2          ✅ PASS
  Hooks                     2          2          ✅ PASS
  Common Prompts            3          3          ✅ PASS
  Prompt names              investigation-guidelines,memory-write-policy,safety-rules  (match)  ✅ PASS
  Scheduled Tasks (unique)  1          1          ✅ PASS
  Response Plans            1          1          ✅ PASS
  Filter names              azmon-sev01 azmon-sev01 ✅ PASS
  Repos                     0          0          ✅ PASS
═══════════════════════════════════════════════════════
  Results: 22 passed, 0 failed
═══════════════════════════════════════════════════════

==> 6.6 - Upload knowledge (app topology + all remediation runbooks)
    Uploads the topology/common-cause doc and every src/remediation-runbooks/*.ps1 (as indexed
    knowledge docs) so the agent knows the layout and mitigations up front, from scratch.

=================== Upload knowledge to SRE Agent ===================
    Agent : sre-checkout (rg-sre-checkout)
    Files : 1 knowledge + 4 runbook doc(s)
==> Uploading checkout-app-topology-and-runbook.md
    ok (indexed for semantic search)
==> Uploading runbook-disable-chaos.md
    ok (indexed for semantic search)
==> Uploading runbook-restart-backend.md
    ok (indexed for semantic search)
==> Uploading runbook-rollback-deploy.md
    ok (indexed for semantic search)
==> Uploading runbook-scale-plan.md
    ok (indexed for semantic search)

    5/5 document(s) uploaded to sre-checkout Knowledge settings.
    Verify in the portal: Builder -> Knowledge settings. New incidents will reference these docs.
-- Phase 6 complete. Press Enter to continue:

==============================================================================
  Lab completion checklist
==============================================================================
    Phase 1: environment resolved, provider registered, alerts present.
    Phase 2: SRE Agent IaC templates acquired.
    Phase 3: agent config generated from the azmon-lawappinsights recipe.
    Phase 4: agent deployed (Microsoft.App/agents + identity + LAW + App Insights + RBAC).
    Phase 5: agent provisioning state confirmed Succeeded.
    Phase 6: SLI + Health Model alerts verified; action group + target scope confirmed.
    Operate: connect Azure Monitor Alerts + GitHub in sre.azure.com, then test with ./sli-alert-scenario.ps1.

    Delete later with:  ./teardown.ps1 -ResourceGroup rg-sre-checkout -AgentName sre-checkout
                        ./teardown.ps1 -ResourceGroup rg-sre-checkout -AgentName sre-checkout -DeleteResourceGroup

    Lab run complete.
```

**One-time portal steps (interactive OAuth, cannot be scripted).** In `sre.azure.com`, open the agent
and:

- Confirm **Azure Monitor Alerts** is the incident source (the recipe sets it; connect it if prompted)
  so alerts on the two managed RGs surface to the agent.
- Connect **GitHub** (`jvargh/azure-reliability-starter-kit`) for deployment/commit correlation.
- Optionally connect ServiceNow/PagerDuty and Slack/Teams for ticketing and notifications.

The agent stays in propose-and-approve mode: it never changes anything without your sign-off.

<details>
<summary>Fallback: create the agent in the portal (preview environments without template access)</summary>

> Optional helper: run `./src/wire-alerts.ps1` first. It registers `Microsoft.App`, resolves the backend
> host and action group, lists the alert rules on both resource groups, and prints the exact values to
> paste into the create wizard below. (The automated path does not need it - `sre-run-lab.ps1` and
> `sli-alert-scenario.ps1` handle all of this.)

1. Go to `https://sre.azure.com` and select **Create agent**.
2. **Basics:** subscription; resource group (create `rg-sre-agent` or reuse one); name `sre-checkout`;
   **Region: East US 2**; Application Insights: **Create new**.
3. **Managed resources:** select **`rg-sli-demo`** and **`rg-healthmodel-demo`**.
4. **Permission level: Reader (recommended).** Actions require your approval. (Move to Privileged later.)
5. **Review + create.** Wait for deployment, then **Chat with agent** to confirm it sees the resources
   ("What Azure resources can you see?").
6. **Incident instructions:** open the agent's settings and paste
   [src/incident-response-plan.md](src/incident-response-plan.md) as the incident response plan / custom
   instructions.
7. **Connect integrations:**
   - **Azure Monitor Alerts** as the incident source (so alerts on the two managed RGs surface to the
     agent).
   - **GitHub**: `jvargh/azure-reliability-starter-kit` for deployment/commit correlation.
   - Optionally ServiceNow/PagerDuty and Slack/Teams for ticketing and notifications.
8. Send a **test incident** to validate enrichment and the proposed-mitigation flow.

</details>

The agent stays in propose-and-approve mode: it never changes anything without your sign-off.

---

## Knowledge and runbooks uploaded to the agent

> This already happened during deploy - **no action needed.** Phase 6.6 of the runner
> (`sre-run-lab.ps1`) runs `upload-knowledge.ps1` for you. The standalone command below is only for
> **re-uploading after you edit** a knowledge doc or runbook.

Phase 6.6 of the runner (`upload-knowledge.ps1`) uploads two kinds of knowledge to the agent's
**Knowledge settings**, indexed for semantic search, so the agent knows the layout and mitigations from
the first incident instead of rediscovering them:

- **App topology + common causes:** [knowledge/checkout-app-topology-and-runbook.md](knowledge/checkout-app-topology-and-runbook.md)
  (services, the telemetry pipeline - metrics live in the Azure Monitor Workspace, not App Insights - the
  SLI recording rules, the fast alert, and the triage/mitigation scenarios).
- **Every remediation runbook:** each `src/remediation-runbooks/*.ps1` is wrapped into an indexed
  markdown doc (`runbook-<name>`) so the agent has the exact steps and commands.

Re-run standalone any time (idempotent, same filenames replace):

```powershell
./upload-knowledge.ps1                 # topology doc + all runbooks
./upload-knowledge.ps1 -SkipRunbooks   # topology doc only
```

The runbooks stay as executable scripts you (or the agent, via the equivalent `az` commands) can run.
All are idempotent, reversible, and auto-discover the backend App Service in `rg-sli-demo`:

| Runbook | When | What it does |
| --- | --- | --- |
| [src/remediation-runbooks/disable-chaos.ps1](src/remediation-runbooks/disable-chaos.ps1) | Injected/demo failure (chaos knobs non-zero) | Resets `errorRate` + `extraLatencyMs` to 0 for each service |
| [src/remediation-runbooks/restart-backend.ps1](src/remediation-runbooks/restart-backend.ps1) | Transient backend state | `az webapp restart` on the backend |
| [src/remediation-runbooks/scale-plan.ps1](src/remediation-runbooks/scale-plan.ps1) | Latency under load | Scales the App Service plan out (`-Instances`) or up (`-Sku`) |
| [src/remediation-runbooks/rollback-deploy.ps1](src/remediation-runbooks/rollback-deploy.ps1) | Regression correlates with a deploy | Lists recent deployments + prints the rollback command |

---

## Trigger the agent: enable the SLI alert and remediate

`sli-alert-scenario.ps1` is the fast demo loop. It enables a Prometheus alert on the SLI (5-minute
window, so it fires in ~2 to 3 minutes rather than waiting on the 1h/6h SLO burn windows), injects a
fault, and hands off to the agent. Run it after the agent is deployed:

```powershell
cd 03-sre-agent
./sli-alert-scenario.ps1
```

What it does:

1. **Enables the fast SLI alert** - a Sev1 Prometheus rule `sli-fast-alerts / CheckoutAvailabilityFastBreach`
   on the Azure Monitor Workspace (checkout `2xx` availability `< 95%`), scoped to `rg-sli-demo` so it lands
   in the agent's managed scope and matches the `azmon-sev01` response plan.
2. **Starts traffic** and **injects the fault** (checkout `errorRate 0.30`, so ~30% of checkout requests
   return HTTP 500), dropping checkout availability below 95%.
3. **Watches** Azure Monitor and reports when the alert fires (severity, scope, elapsed).
4. **Hands off to the agent:** it ingests the Sev1 alert, investigates, and (with the app knowledge it now
   has) proposes/executes the fix - restart the backend or reset chaos - which clears the 500s. Availability
   recovers and the alert auto-resolves (~5 min).

```powershell
./sli-alert-scenario.ps1 -EnableOnly     # just create the alert (no fault)
./sli-alert-scenario.ps1 -TeardownAlert  # remove the alert, reset chaos, stop traffic
```

Open the agent's **Incidents** in `sre.azure.com` to watch it engage and approve the proposed remediation
(unless you granted it write access to act unattended).

> Note: the SLI's "linked" metric alerts on the SLI blade are display-only (they do not fire), and
> Health Model alerts (rg-healthmodel-demo) are not ingested by the agent. The agent's Azure Monitor
> incident source ingests alerts from rg-sli-demo, so `sli-fast-alerts` (what this script creates) is
> the trigger. Recovery check: checkout availability climbs back above 95% and the alert resolves.

---

## Troubleshooting

- **No alerts reach the agent:** confirm the SLI burn-rate alerts and Health Model health-state alerts
  exist and are enabled (`src/wire-alerts.ps1` lists them), and that the agent's managed resource groups
  include `rg-sli-demo` and `rg-healthmodel-demo`.
- **Agent has no resources:** it needs at least Reader on the managed resource groups; re-check the
  create wizard's permission step or add access from **Settings > Managed resources**.
- **Signals still Unknown after a fix:** signals evaluate every minute and read the SLI `:value`; give it
  a few cycles with traffic flowing.
- **`Create` disabled / DeploymentNotFound:** register the provider with `az provider register --namespace Microsoft.App` and retry.

---

## Related files

- [README.md](README.md) - phase overview + state-to-response table.
- [src/incident-response-plan.md](src/incident-response-plan.md) - the agent instructions.
- [../01-sli-demo/load/inject-degradation.md](../01-sli-demo/load/inject-degradation.md) - the chaos knobs this lab drives.
- [../02-healthmodel-demo/Health-Model-Lab-UserGuide.md](../02-healthmodel-demo/Health-Model-Lab-UserGuide.md) - the health-state alerts that trigger remediation.
- [SRE Agent overview](https://learn.microsoft.com/azure/sre-agent/overview) - [Create agent](https://learn.microsoft.com/azure/sre-agent/create-agent)
