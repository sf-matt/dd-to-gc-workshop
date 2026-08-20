# DD → GC Workshop: Telemetry, Dashboard & Monitors

This covers the Datadog side only — the piece to migrate to groundcover afterward.

## Telemetry sources (what actually produces the data below)

1. **Datadog Agent** (Operator, reusing your existing values — `DD_HOSTNAME` downward-API
   fix + `kubelet.tlsVerify: false`) → infra & container metrics, autodiscovery, log
   collection.
2. **APM via Single Step Instrumentation** (Cluster Agent admission controller) → traces
   for `order-api` and `payment-svc`, **zero code changes**. Enable per-namespace:

   ```yaml
   # DatadogAgent CR, spec.features
   apm:
     instrumentation:
       enabled: true
       targets:
         - name: "workshop-namespace"
           namespaceSelector:
             matchNames: ["workshop"]
           ddTraceVersions:
             python: "default"
   ```

   This is the reason the dashboard below has real request/error/latency data instead of
   just CPU/memory — and it's the exact signal groundcover's eBPF sensor derives without
   any admission controller at all, which is the parity moment worth calling out live.

3. **(Optional) DogStatsD custom metric** — if you want a visible "chaos mode" indicator,
   have `payment-svc` emit `payment.chaos.enabled` (gauge, 0/1) via the DogStatsD sidecar.
   Not required for the dashboard/monitors below; skip it if you want to keep telemetry
   surface minimal.

## Metric facts used here (verified against current Datadog docs, not guessed)

- `trace.http.request.hits`, `.errors`, `.duration` are **auto-generated for any
  HTTP/web APM service** — tagged by `env`, `service`, `resource_name`,
  `http.status_code`. They're calculated on 100% of traffic regardless of trace sampling,
  and are safe to use in dashboards/monitors like any other metric (15-month retention
  once referenced).
- `span_name: "flask.request"` is the Flask root-span operation name Single Step
  Instrumentation produces. If you swap in a different framework, check **APM > Traces**
  for the actual root span name before importing — it does vary by framework/version.
- `trace.http.request.duration` is in **seconds**, not milliseconds — the latency monitor
  threshold (`0.5`) reflects that.

## Files

- `dashboard.json` — "DD→GC Workshop: Order Flow Service Health" dashboard. Three groups:
  Service Overview (APM `trace_service` widgets — the built-in widget type, so no
  hand-rolled query risk), Latency & Errors, Infra & Kubernetes, plus an error log stream.
- `monitors.json` — 5 monitors mapped 1:1 to what the dashboard shows: error rate,
  p95 latency, no-traffic/service-down, pod restarts, memory pressure. These are what
  you'll recreate as groundcover alerts for the parity check.

## Importing

**Dashboard:**
```bash
curl -X POST "https://api.us3.datadoghq.com/api/v1/dashboard" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

**Monitors** (loop since the endpoint takes one object at a time):
```bash
jq -c '.[]' monitors.json | while read -r monitor; do
  curl -X POST "https://api.us3.datadoghq.com/api/v1/monitor" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d "$mononitor"
done
```
(Note: `us3.datadoghq.com` — matches your existing site; swap the base URL if attendees
are on a different Datadog site.)

Both also import fine via the UI: **Dashboards > New Dashboard > Import Dashboard JSON**
and **Monitors > New Monitor > Import** (paste each object individually, or use Terraform
if you'd rather manage these as code for repeatability across attendee clusters).
