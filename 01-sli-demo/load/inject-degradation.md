# Injecting degradation to burn the error budget

The backend exposes `/admin/chaos` to tune failure rate and latency per service. Keep the load generator running while you inject so the SLI signals move.

Set `$be` to your backend host first:

```powershell
$be = "https://<backend-app-name>.azurewebsites.net"
```

## Fast burn (sudden regression, pages on-call)

```powershell
Invoke-RestMethod -Method Post "$be/admin/chaos" `
  -Body (@{ service = "checkout"; errorRate = 0.08 } | ConvertTo-Json) `
  -ContentType "application/json"
```

~8% of checkouts return 5xx. The availability SLI drops well below 99.5% and the fast-burn alert fires within its short lookback.

## Slow burn (sustained degradation)

```powershell
Invoke-RestMethod -Method Post "$be/admin/chaos" `
  -Body (@{ service = "checkout"; errorRate = 0.015 } | ConvertTo-Json) `
  -ContentType "application/json"
```

Leave running. A steady ~1.5% error rate consumes the budget gradually and triggers the slow-burn alert after sustained consumption.

## Latency burn (requests exceed 300 ms)

```powershell
Invoke-RestMethod -Method Post "$be/admin/chaos" `
  -Body (@{ service = "login"; extraLatencyMs = 600 } | ConvertTo-Json) `
  -ContentType "application/json"
```

Adds 600 ms to login, pushing login requests above the 300 ms threshold so the latency SLI budget burns.

## Recover

```powershell
Invoke-RestMethod -Method Post "$be/admin/chaos" -Body (@{ service = "checkout"; errorRate = 0; extraLatencyMs = 0 } | ConvertTo-Json) -ContentType "application/json"
Invoke-RestMethod -Method Post "$be/admin/chaos" -Body (@{ service = "login"; errorRate = 0; extraLatencyMs = 0 } | ConvertTo-Json) -ContentType "application/json"
```

Burn rate falls below 1 and the alerts resolve. Check current settings any time with:

```powershell
Invoke-RestMethod "$be/admin/chaos"
```
