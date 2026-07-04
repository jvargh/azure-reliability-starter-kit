# Runbook 2: Baseline and burn-rate alerts

Configure these on the **Baseline + Alert** tab when creating or editing an SLI. All three alert types share an action group.

## Action group

Create once (portal: **Monitoring** > **Alerts** > **Action groups** > **Create**), or with CLI:

```powershell
az monitor action-group create `
  -g rg-sli-demo `
  -n ag-sli-demo `
  --short-name sliDemo `
  --action email oncall <oncall-email>
```

Add Teams/webhook/ITSM receivers as needed for the customer.

## Alert types

On the **Baseline + Alert** tab, turn on **Enable Alert**, then configure:

| Alert | When it fires | Lookback | Use |
| --- | --- | --- | --- |
| **Baseline alert** | SLI falls below the baseline over the evaluation period | Evaluation period (7d) | Compliance miss notification |
| **Fast burn rate** | Error budget is consumed rapidly | Short (for example 1h) | Catch sudden regressions / bad deploys |
| **Slow burn rate** | Error budget is consumed steadily over time | Long (for example 6h) | Catch sustained degradation |

Bind each to **`ag-sli-demo`** under **Action groups**.

## Recommended burn-rate settings for a 99.9% / rolling window demo

| Alert | Burn-rate multiple | Lookback | Meaning |
| --- | --- | --- | --- |
| Fast burn | ~14x | 1h | ~2% of budget consumed in an hour -> page now |
| Slow burn | ~3x | 6h | ~10% consumed over 6h -> investigate |

These multiples are starting points; tune to the customer's traffic volume and on-call tolerance.

## Demo trigger cheat-sheet

| To show | Inject | Expected alert |
| --- | --- | --- |
| Fast burn | `checkout` errorRate `0.08` | Fast-burn fires within the short lookback |
| Slow burn | `checkout` errorRate `0.015` left running | Slow-burn fires after sustained consumption |
| Latency burn | `login` extraLatencyMs `600` | Latency SLI budget burns, P95 > 300 ms |
| Recovery | set rates back to `0` | Burn rate returns below 1, alert resolves |

Injection commands are in [../load/inject-degradation.md](../load/inject-degradation.md).
