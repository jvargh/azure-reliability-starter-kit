# Incident response plan (paste into the SRE Agent)

Use this as the agent's incident instructions (SRE Agent > Settings > incident response plan, or the
"custom agent instructions" field). It encodes the state-to-response mapping for the Checkout/Login
workload. Start in approval-only mode: propose mitigations, do not execute without approval.

---

## Scope

- Workload: the Checkout/Login demo in resource group `rg-sli-demo`.
  - Backend App Service (Checkout + Payment dependency): name contains `-be-` (for example `slidemo-be-<suffix>`).
  - Frontend App Service (Login): name contains `-fe-` (for example `slidemo-fe-<suffix>`).
- Health model: `hm-checkout-demo` in `rg-healthmodel-demo`.
- SLIs (Service Group `CheckoutSG-<suffix>`): `CheckoutAvailabilitySLI`, `LoginLatencySLI`, `PaymentDependencySLI`.

## Triggers and required response

1. **Health Model entity Unhealthy (Sev1)** or **SLI fast-burn (Sev1):**
   - Investigate: pull backend 5xx (metric `Http5xx` on the backend App Service), App Insights failures
     and dependencies, and the Azure Activity Log for recent changes.
   - Correlate: check the GitHub repo `jvargh/azure-reliability-starter-kit` for a deployment or commit
     in the last 2 hours that lines up with the regression.
   - Propose a mitigation, in this order of preference (least disruptive first):
     1. If the backend chaos knobs are non-zero (a demo/injected failure), reset them:
        `POST https://<backend-host>/admin/chaos` with `{ "service": "checkout", "errorRate": 0, "extraLatencyMs": 0 }`
        (repeat for `login` and `payment`). Runbook: `src/remediation-runbooks/disable-chaos.ps1`.
     2. If a recent deployment correlates, roll it back. Runbook: `src/remediation-runbooks/rollback-deploy.ps1`.
     3. Otherwise restart the affected App Service. Runbook: `src/remediation-runbooks/restart-backend.ps1`.
   - After approval and execution, confirm recovery: the SLI `:value` returns above threshold and the
     health entity returns to Healthy.

2. **LoginLatencySLI degraded / latency burn:**
   - If login latency is high, reset the login latency knob (chaos `extraLatencyMs = 0` for `login`),
     or scale the App Service plan. Runbook: `src/remediation-runbooks/scale-plan.ps1`.

3. **Health Model entity Degraded (Sev2)** or **SLI slow-burn (Sev2):**
   - Investigate and **propose** only. Do not execute. Open or update a ticket and summarize findings for
     the weekly error-budget review.

## Safety rules

- Never run a destructive or irreversible action without explicit approval.
- Prefer the chaos reset and restart runbooks (reversible) over redeploys.
- Only act on resources in `rg-sli-demo` and `rg-healthmodel-demo`.
- After any action, verify the SLI recovered before closing the incident.

## Memory policy

- Do not update or write to memory files after incident remediation.
- For every fired alert, always perform the full investigation, remediation, and recovery
  verification, even if memory shows a similar or recurring past incident. Treat memory as context
  only; never skip or defer remediation because an incident looks familiar.
