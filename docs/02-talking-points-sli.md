# Talking Points: Designing SLIs from User Journeys

Start with the SLI concepts in the first image, then use the process overview in
[SLI-Lab-UserGuide.md](../01-sli-demo/SLI-Lab-UserGuide.md) to explain how the lab moves from a running
application to validated SLIs.

## Start with why SLI-based reliability matters

Traditional monitoring tells us about CPU, memory, logs, and resource health. Those signals are useful,
but they do not directly answer the customer question: did the journey work?

SLI-based reliability starts with that customer question. For checkout, we ask whether the request
succeeded. For login, we ask whether the request completed within the expected time. This changes the
focus from the health of a machine to the result experienced by the user.

The first building block is the Service Level Indicator, or SLI. It is the measurement. If 99.87 percent
of checkout requests succeed, that is the checkout availability SLI.

The second is the Service Level Objective, or SLO. This is the target and time window we commit to. In
this demo, the target is 99.5 percent over a rolling seven-day window.

The third is the error budget. A 99.5 percent objective allows 0.5 percent failure before the service
misses the objective.

The fourth is burn rate: how quickly the service is spending the budget. A rate of 1x is sustainable. A
much higher rate means the budget will be exhausted early, so the alert becomes urgent.

These four values come from the same chain: measure the experience with an SLI, set the target with an
SLO, calculate the allowed failure as the error budget, and alert on how quickly that budget is burning.

## Explain how we arrive at the right SLIs

The lab does not begin by guessing which SLIs to create in the portal. It starts with the application and
narrows it down to the user journeys that matter most.

The starting point is a deployed application with continuous traffic because the lab uses live request
metrics and rolling rate windows. Path A runs the process with `sli-run-lab.ps1`; Path B runs the same
commands manually. Automation changes how the work is performed, not the design method.

Phase 1 checks the environment and confirms that the telemetry is available. The lab resolves the Azure
Monitor Workspace and Application Insights resources, verifies access, and checks that request metrics
are arriving. If there is no live data, the process stops because there is no evidence on which to design
an SLI.

Phase 2 enumerates all user journeys from telemetry, including login, checkout, and the payment dependency.
This avoids designing SLIs only for journeys already familiar to the team.

Phase 3 reduces that inventory to the critical journeys. Each journey is scored using frequency,
business impact, customer visibility, and blast radius. Telemetry can provide the traffic frequency, but
the other scores require human judgement. The output is a short list of journeys that are strong SLI
candidates.

Phase 4 collects evidence for each critical journey. We confirm that the source metric has the dimensions
needed to isolate the journey. We measure current performance, check that the signal is continuous, and
write the contract for good and valid events. For checkout availability, good means successful checkout
requests and valid means all checkout requests. For login latency, good means requests completed within
the latency threshold and valid means all login requests.

Phase 5 turns that evidence into the design checklist. Each row is a complete SLI specification: journey,
SLI type, source metric, filters, good and valid definitions, measured performance, target, rolling window,
error budget, and burn-alert policy. No new measurement decisions should be introduced here. The checklist
consolidates the evidence already gathered.

Phase 6 authors each checklist row as an SLI on the Service Group. This is where the abstract design maps
to the Azure fields. Path A can call `deploy-sli.ps1` to create the recording rules, Service Group,
membership, and SLIs. Path B uses the same checklist to complete the portal form field by field.

Phase 7 confirms that the SLI engine publishes the evaluated `:value` series and that it agrees with the
good and total signals. Phase 8 summarizes the checkpoints and confirms completion.

## Close with the result

The result in this demo is three SLIs: checkout availability, login latency, and payment dependency
availability. They were not selected because those names looked useful in a portal. They came from the
same repeatable chain: inventory the journeys, select the critical ones, gather evidence, define good and
valid events, commit to a target, author the SLIs, and validate the published results.

That is the core message. Path A makes the process faster, and Path B makes every step visible, but both
produce SLIs that are traceable to a real customer journey and supported by real telemetry.