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

## Metric facts used here (verified live against this org's actual data via the
## Datadog MCP server, not just docs — see "Verified against live data" below)

- The auto-generated APM metrics follow **`trace.<root-span-operation-name>.*`**, not a
  generic `trace.http.request.*` name. For these Flask services under Single Step
  Instrumentation, the root span operation name is `flask.request`, so the real metrics
  are `trace.flask.request` (duration distribution, seconds, percentiles enabled),
  `trace.flask.request.hits` (count), and `trace.flask.request.hits.by_http_status`
  (count, additionally tagged `http.status_code` and `http.status_class` e.g. `5xx`).
  There is no separate `.errors` count metric — use `.hits.by_http_status` filtered to
  `http.status_class:5xx` for error counts.
- order-api's outbound call to payment-svc (via the `requests` library) generates its
  own client-span metric family: `trace.requests.request`, `.hits`, and
  `.hits.by_http_status`, tagged `service:order-api` + `peer.service:payment-svc`. This
  is the dependency-call signal used by the new "Service Dependencies" group/monitor
  below — the same signal groundcover's eBPF sensor derives without any admission
  controller, which is the parity moment worth calling out live.
- All of the above are tagged by `env`, `service`, `resource_name`, `http.status_code`.
  They're calculated on 100% of traffic regardless of trace sampling, and are safe to
  use in dashboards/monitors like any other metric (15-month retention once referenced).
- `span_name: "flask.request"` is the Flask root-span operation name Single Step
  Instrumentation produces, and doubles as the metric-name segment above. If you swap in
  a different framework, check **APM > Traces** for the actual root span name before
  importing — it does vary by framework/language, and the generic `trace.http.request.*`
  name attendees may find in older Datadog examples does not apply here.
- `trace.flask.request` / `trace.requests.request` are in **seconds**, not
  milliseconds — the latency monitor thresholds (`0.5`) reflect that.

### Verified against live data

The original version of this dashboard/these monitors shipped with `trace.http.request.*`
queries, which **do not exist in this org** — confirmed via the Datadog MCP server's
metric search against the live `us3.datadoghq.com` site. That's why 3 of the 5 originally
imported monitors (error rate, p95 latency, no-traffic) were sitting in "No Data" status
even though the services were actively receiving traffic — the k8s-metric monitors (pod
restarts, memory) were unaffected since those metric names were always correct. All
queries in the current `dashboards/*.json`/`monitors.json` have been dry-run against this
org's real metrics and confirmed to return data (not just confirmed syntactically valid).
If you re-run this workshop against a different Datadog org/language stack, re-verify the
root span operation name before trusting these metric names again.

## Files

- `dashboards/` — **5 standalone dashboards** (split out from one combined dashboard so
  each can be opened, shared, and rebuilt in groundcover independently):
  1. `01-service-overview.json` — APM `trace_service` built-in widgets for both services.
  2. `02-latency-errors.json` — per-service latency percentiles + error rate %.
  3. `03-service-dependencies.json` — the order-api → payment-svc call specifically,
     isolated via its client-span metric (`trace.requests.request.*`).
  4. `04-infra-kubernetes.json` — pod CPU/memory/restarts (works even without APM).
  5. `05-logs.json` — recent request logs + error-log streams, plus a note widget
     flagging the log-severity caveat below.
- `monitors.json` — 9 monitors: the original 5 payment-svc monitors (error rate, p95
  latency, no-traffic/service-down, pod restarts, memory pressure — with corrected
  queries), plus 4 new ones covering order-api parity (error rate, no-traffic, pod
  restarts) and the order-api → payment-svc dependency-call error rate. These are what
  you'll recreate as groundcover alerts for the parity check.
- `log-pipeline.json` — a Datadog log processing pipeline (grok parser + status remapper)
  that fixes the log-severity bug described below. Pure Datadog-side config, no app code.
- `provision-student.sh` — renders + imports a per-student copy of all 5 dashboards and
  9 monitors into this same org, scoped to that student's own `env` tag. See
  "Multi-student provisioning" below.

## Multi-student provisioning (many students, one shared Datadog org)

Every dashboard/monitor query here is scoped by an `env` tag (default `workshop`). All
container telemetry — traces, infra metrics, *and* logs — inherits `env` from the
`tags.datadoghq.com/env` pod label already set on the `order-api`/`payment-svc`
Deployments (Datadog's Unified Service Tagging applies that label to every signal the
Agent collects from that pod, not just APM). That single tag is what keeps one student's
data from mixing into another's when many students each run their own Kind cluster but
all ship into the same Datadog org.

Two scripts, one for each side, that must agree on the same student name:

```bash
# Datadog side — you run this once per student, into your own org
./observability/provision-student.sh alice

# k8s side — alice runs this herself, on her own machine, against her own checkout
./k8s/provision-student.sh alice
```

`observability/provision-student.sh` renders and `POST`s a titled, `env:workshop-alice`-
scoped copy of every dashboard and monitor (rendered JSON + an id manifest land under
`observability/.provisioned/alice/`, gitignored — keep it if you'll need the ids later
for cleanup or `PUT` updates).

`k8s/provision-student.sh` renders `k8s/10-payment-svc.yaml` and `k8s/20-order-api.yaml`
with `tags.datadoghq.com/env` set to `workshop-alice` (both occurrences in each file —
`metadata.labels` and `spec.template.metadata.labels`), copies the two manifests that
don't need per-student changes (`00-namespace.yaml`, `30-load-generator.yaml`) alongside
them, and client-side-validates the result — all under `k8s/.provisioned/alice/`, also
gitignored, ready to `kubectl apply -f k8s/.provisioned/alice/`. It never touches a live
cluster itself; each student runs it against their own. Order between the two scripts
doesn't matter, but a student's telemetry won't show up on their dashboards until both
have run — the `env` values have to match, which is why both scripts derive it from the
same `workshop-<name>` convention rather than taking it as a free-form argument.

Pass a second argument to `observability/provision-student.sh` to point a student's
monitors at their own Slack handle instead of the shared `@slack-workshop-alerts`:
`./provision-student.sh alice @slack-alice-alerts`.

**What this does not give you:** Datadog's tag-based **Restriction Queries** (Data
Access Control) can scope what each student's *own* Datadog user account can see in
Explorers/dashboards to their `env:workshop-<name>` data — but monitors evaluate as a
system user with full data access regardless of who's viewing, so a student's monitor
staying correctly scoped depends entirely on the `env:workshop-<name>` filter baked into
its query by this script, not on RBAC. Dashboard/monitor *objects* are also visible
org-wide by default (any student with read access can list everyone's) — Datadog's
per-dashboard edit-restriction is self-serve, but view-restriction currently requires
asking your account team to enable it. The `— <name>` title suffix and `student:<name>`
monitor tag this script adds are there so students can find their own by name, not to
hide anyone else's.

## Log severity caveat (why `05-logs.json` ships a pipeline dependency)

Flask's built-in dev server (`werkzeug`) writes its access log — **every** request,
regardless of status code — to stderr. The Datadog Agent defaults stderr container logs
to `status:error`. Verified live: every `order-api`/`payment-svc` log line, including
plain `200` responses, currently shows up tagged `status:error` in this org. That means a
naive `service:payment-svc status:error` log query (as used in the original single
dashboard) shows 100% of traffic, not real errors.

This is not a reason to add app-level logging/instrumentation — it's a Datadog-side log
pipeline gap. `log-pipeline.json` adds a grok parser that extracts the real HTTP status
code from the werkzeug access-log message (`"METHOD PATH HTTP/1.1" STATUS SIZE`) and
remaps log status from it, so `status:error` becomes accurate **going forward** (it does
not retroactively reclassify already-ingested logs). See "Importing" below for how to
push it.

## Updating already-imported objects

If you've already imported an earlier version of these dashboards/monitors into this org
(as was the case here), re-running the `POST` commands below will create duplicates, not
update in place. Use `PUT` with the existing id instead:

```bash
curl -X PUT "https://api.${DD_SITE}/api/v1/dashboard/<dashboard_id>" \
  -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" -d @dashboards/<file>.json

curl -X PUT "https://api.${DD_SITE}/api/v1/monitor/<monitor_id>" \
  -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" -d '<single monitor object from monitors.json>'

curl -X PUT "https://api.${DD_SITE}/api/v1/logs/config/pipelines/<pipeline_id>" \
  -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" -d @log-pipeline.json
```

Look up existing ids with `GET /api/v1/dashboard`, `GET /api/v1/monitor`, or
`GET /api/v1/logs/config/pipelines` (or the Datadog MCP server's search tools) before
deciding whether to `PUT` or `POST` each object.

## Importing

All commands read `DD_API_KEY`, `DD_APP_KEY`, and `DD_SITE` from your shell —
copy `.env.example` to `.env` at the repo root, fill in your keys, and
`source .env` first.

**Dashboards** (one POST per file, in order):
```bash
for f in dashboards/*.json; do
  curl -X POST "https://api.${DD_SITE}/api/v1/dashboard" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d @"$f"
done
```

**Monitors** (loop since the endpoint takes one object at a time):
```bash
jq -c '.[]' monitors.json | while read -r monitor; do
  curl -X POST "https://api.${DD_SITE}/api/v1/monitor" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d "$monitor"
done
```

**Log pipeline:**
```bash
curl -X POST "https://api.${DD_SITE}/api/v1/logs/config/pipelines" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" \
  -d @log-pipeline.json
```

All three also import fine via the UI (**Dashboards > New Dashboard > Import Dashboard
JSON**, **Monitors > New Monitor > Import**, **Logs > Pipelines > New Pipeline**), or via
Terraform if you'd rather manage these as code for repeatability across attendee clusters.
