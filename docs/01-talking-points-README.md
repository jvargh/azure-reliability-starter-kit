# Talking Points: From SLIs to a Reliability Operating Model

## Start with the implementation flow

Start at the top with a customer request. The request first reaches the frontend web app, which runs on
Azure App Service. The frontend calls the backend API for the `/login` or `/checkout` operation. During
checkout, the backend also calls the simulated payment dependency. The response then returns through the
frontend to the customer.

As the frontend and backend process that request, they emit telemetry along two paths. OpenTelemetry sends
request counters and latency histograms to the OpenTelemetry Collector. The collector converts them to
Prometheus format and sends them to a remote-write proxy. The proxy adds managed-identity authentication
and writes the metrics into the Azure Monitor Workspace.

At the same time, the Application Insights SDK sends request traces, dependency calls, and failures to
Application Insights, backed by Log Analytics. The Azure Monitor Workspace therefore holds the metrics
used for reliability calculations, while Log Analytics holds the detailed traces and logs used during an
investigation.

The frontend and backend belong to the `CheckoutSG` Service Group. The Service Group defines the
application boundary for the SLIs. The SLI engine reads the request metrics from the Azure Monitor
Workspace. It calculates availability from successful requests divided by total valid requests, and it
calculates latency from requests completed within the target time. It writes the evaluated SLI results
back to the same workspace.

The SLI engine compares those results with the SLO and calculates the remaining error budget and burn
rate. If the service consumes the budget too quickly, a burn-rate alert is created in Azure Monitor.

The Health Model also reads the evaluated SLI result from the Azure Monitor Workspace through a PromQL
signal. It can combine that result with signals from Log Analytics and Azure resources. The model then
rolls the signals up into a Healthy, Degraded, or Unhealthy application state. A state change can create a
Health Model alert.

Azure Monitor sends alerts to the configured Action Group for human notification. For the automated demo,
the fast SLI alert is also the verified incident trigger for the SRE Agent. The agent receives the alert,
checks the application telemetry, Azure activity, recent deployments, and uploaded runbooks, and then
proposes or executes the approved remediation.

The remediation changes the application, for example by clearing the injected checkout failure. New
requests pass through the same path, new metrics reach the workspace, and the SLI engine recalculates
availability. The SLI returns above its target and the alert resolves, confirming recovery.

In parallel, the error-budget result drives the operating decision. If the budget is healthy, the team can
continue to ship. If it is burning too quickly, the team pauses and stabilizes the service.

## Walk through the phases

### Phase 0: SLIs and SLOs

Phase 0 builds the foundation. We start with metrics in the Azure Monitor Workspace and define the customer
journeys that matter, such as login and checkout. We then author availability and latency SLIs, set the SLO,
and enable error-budget and burn-rate alerts.

Every later phase depends on this foundation. The SLI answers the question, "Are customers receiving the
experience we promised?" It shifts the focus from infrastructure metrics to a customer outcome.

### Phase 1: Health Models

Phase 1 builds an application health view on top of those SLIs. We create the Health Model, discover the
application resources, and add signals from metrics, logs, and the SLI results. We then set the thresholds
for degraded and unhealthy states.

The Health Model does not replace the SLI. It uses the SLI to produce an application health score, with a
path to the service or signal that is failing.

### Phase 2: SRE Agent

Phase 2 connects the alerts to the SRE Agent. A fast SLI burn alert or a Health Model state alert is sent
through Azure Monitor. The SRE Agent receives the incident and begins the first part of the investigation.

It checks application telemetry, recent Azure activity, and deployment history. It also uses the uploaded
application knowledge and remediation runbooks. Based on that evidence, it can propose or execute an
approved remediation. The final test is not simply whether the command succeeded. The final test is whether
the SLI returns to a healthy value.

### Phase 3: Operating model

Phase 3 turns these technical signals into a working practice. Teams review the SLI, application health,
incidents, and remaining error budget together. A healthy budget supports shipping new features. A rapidly
burning budget tells the team to focus on reliability.

The main point is simple: the SLI is the thread through the entire flow. It measures the customer experience,
feeds the Health Model, triggers the incident response, confirms recovery, and guides the decision to ship or
stabilize. We start with one trustworthy customer-focused number, then use each phase to make that number more
useful.