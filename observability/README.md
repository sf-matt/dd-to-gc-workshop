# DD → GC Workshop: Telemetry, Dashboard & Monitors

This covers the Datadog side only — the piece to migrate to groundcover afterward.

## Student Setup

Every student signs up for their own free Datadog trial (14 days, no credit card —
Google sign-in works, covers everything this workshop uses: APM, Logs, Dashboards,
Monitors) and runs this entirely on their own. Nobody needs to share a Datadog org, an
API key, or coordinate a name with anyone else — each of you owns your whole org, so
there's nothing to scope or collide with. Run this top to bottom.

*(Running this as a shared lab out of one Datadog org instead — e.g. trials genuinely
aren't an option for your group — is still possible but meaningfully more setup. See
[Shared lab (fallback)](#shared-lab-fallback) at the bottom instead of this section.)*

### Prerequisites

- Docker Desktop (or another local Docker daemon), running
- `kind`, `kubectl`, `helm`, `jq` — on macOS: `brew install kind kubectl helm jq`

```bash
git clone https://github.com/sf-matt/dd-to-gc-workshop.git
cd dd-to-gc-workshop
```

### 1. Get your keys

Sign up at [datadoghq.com](https://www.datadoghq.com/free-datadog-trial/) (Google
sign-in is the fastest path — no credit card either way). Once you're in: **Organization
Settings > API Keys** and **> Application Keys**, create one of each.

### 2. Fill in your credentials

```bash
cp .env.example .env
# edit .env — set DD_API_KEY, DD_APP_KEY, and DD_SITE (the domain in your browser's
# address bar once logged in, e.g. us1.datadoghq.com, us5.datadoghq.com, datadoghq.eu)
source .env
```

**If your site isn't `datadoghq.com` (us1)**, also update `k8s/datadog-agent.yaml` —
`spec.global.site` is a separate, hardcoded value the Agent itself uses, independent of
`DD_SITE` in `.env`. Getting these two out of sync is a real trap: the Agent authenticates
fine (right API key) but silently can't deliver anything (wrong site), and the failure
mode is a 403 on every intake endpoint that just looks like an auth problem. `.env`'s
`DD_SITE` only affects the `curl` commands in this file; it does nothing for the Agent.

```bash
sed -i '' "s/site: .*/site: ${DD_SITE}/" k8s/datadog-agent.yaml   # macOS
# sed -i "s/site: .*/site: ${DD_SITE}/" k8s/datadog-agent.yaml    # Linux
```

### 3. Stand up the cluster and app

```bash
kind create cluster --config kind-config.yaml
docker build -t order-api:local apps/order-api
docker build -t payment-svc:local apps/payment-svc
kind load docker-image order-api:local --name workshop
kind load docker-image payment-svc:local --name workshop

kubectl apply -f k8s/00-namespace.yaml
helm repo add datadog https://helm.datadoghq.com
helm repo update datadog
helm install datadog-operator datadog/datadog-operator -n datadog
kubectl create secret generic datadog-secret --from-literal api-key="$DD_API_KEY" -n datadog
kubectl apply -f k8s/datadog-agent.yaml
kubectl wait --for=condition=available --timeout=180s deployment/datadog-cluster-agent -n datadog

kubectl apply -f k8s/10-payment-svc.yaml -f k8s/20-order-api.yaml -f k8s/30-load-generator.yaml
```

### 4. Import the dashboards, monitors, and log pipeline into your own org

```bash
cd observability

for f in dashboards/*.json; do
  curl -X POST "https://api.${DD_SITE}/api/v1/dashboard" \
    -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" -d @"$f"
done

jq -c '.[]' monitors.json | while read -r monitor; do
  curl -X POST "https://api.${DD_SITE}/api/v1/monitor" \
    -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" -d "$monitor"
done

curl -X POST "https://api.${DD_SITE}/api/v1/logs/config/pipelines" \
  -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
  -H "Content-Type: application/json" -d @log-pipeline.json

cd ..
```

**Done.** Give it a couple of minutes, then check **APM > Traces** in your Datadog org
for `order-api` and `payment-svc` — you should see live traffic from `load-generator`.

**One thing you'll probably see that isn't from this repo:** a fresh trial org
auto-generates its own **Recommended Monitors** the moment Datadog notices your
Kubernetes/APM integration data — 15-20 of them, named things like `[Kubernetes] Pod
{{pod_name.name}} is CrashloopBackOff...` or `CPU usage is high for host {{host.name}}`,
created by `Datadog Support`, tagged `monitor_pack:kubernetes`/`monitor_pack:host`/
`monitor_pack:apm`. That's Datadog's own onboarding behavior, not this workshop's
`monitors.json` — you can tell them apart by that `creator`/`monitor_pack` tag, or just
by name (this repo's are all prefixed `[Workshop]`). The `{{...}}` in their titles isn't
broken; it's the same multi-alert templating this repo's own monitors use, resolving to
a real pod/host name only once that specific one fires. Harmless to leave, or delete
them (**Monitors > search `monitor_pack:*` > Delete**) if you want a clean, workshop-only
view before you start comparing against groundcover.

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
- `provision-student.sh` — fallback tool, only needed for the shared-lab setup (see
  below) — renders + imports a per-student copy of all 5 dashboards and 9 monitors into
  a shared org, scoped to that student's own `env` tag. Not used when every student has
  their own trial (the default — see **Student Setup** above).

## Shared lab (fallback)

Many students, one shared Datadog org, instead of each student on their own trial.
Skip this whole section if every student can get their own trial (the default — see
**Student Setup** at the top). Use this instead only when that's genuinely not an
option — e.g. trial signups are blocked for your group. It's real setup work: students
share one org, so their resources have to stay scoped to them individually, and that
scoping has to be coordinated by hand between you and each student.

### Student side

Same **Prerequisites** and `git clone` as Student Setup above, then:

**1. Get your API key.** Either your instructor hands it to you directly, or: log into
the shared org they invited you to, go to **Organization Settings > API Keys**, and copy
an existing key (or create your own, if your role allows it). **You do not need an
Application Key or an `.env` file for this path** — just the one API key.

```bash
export DD_API_KEY="<the key you were given>"
```

**2. Stand up your cluster and Agent** — identical to Student Setup step 3, except the
secret uses the key above instead of one from `.env`:

```bash
kind create cluster --config kind-config.yaml
docker build -t order-api:local apps/order-api
docker build -t payment-svc:local apps/payment-svc
kind load docker-image order-api:local --name workshop
kind load docker-image payment-svc:local --name workshop

kubectl apply -f k8s/00-namespace.yaml
helm repo add datadog https://helm.datadoghq.com
helm repo update datadog
helm install datadog-operator datadog/datadog-operator -n datadog
kubectl create secret generic datadog-secret --from-literal api-key="$DD_API_KEY" -n datadog
kubectl apply -f k8s/datadog-agent.yaml
kubectl wait --for=condition=available --timeout=180s deployment/datadog-cluster-agent -n datadog
```

**3. Deploy the app tagged with your name** — this replaces Student Setup step 3's plain
`kubectl apply -f k8s/10-payment-svc.yaml ...` with a version scoped to you:

```bash
./k8s/provision-student.sh
```

With no argument it prompts — `Enter your full name:` — and turns whatever you type into
a clean identifier (lowercased, spaces/punctuation collapsed to hyphens — "Jane Doe"
becomes `jane-doe`), shows you both, and asks you to confirm before doing anything. It
won't run past that prompt with nothing typed. Once confirmed:

```bash
kubectl apply -f k8s/.provisioned/<the identifier it printed>/
```

**Then tell your instructor the exact identifier the script printed** (the line that
says `Using identifier: ...`) — not just your name in prose. That's the string they need
to pass to their own script for your data to line up; if they retype your name by hand
instead and it doesn't slugify to the exact same thing (different accents, spacing,
capitalization), your dashboards will look for data that never shows up.

You never touch anything under `observability/` yourself in this path — your instructor
provisions your dashboards/monitors using the identifier you send them. Once traffic
starts flowing, find yours in the shared org by searching for your name: dashboard
titles end in `— <your name as you typed it>`, and your monitors are tagged
`student:<identifier>`.

### Instructor side

Every dashboard/monitor query here is scoped by an `env` tag (default `workshop`). All
container telemetry — traces, infra metrics, *and* logs — inherits `env` from the
`tags.datadoghq.com/env` pod label already set on the `order-api`/`payment-svc`
Deployments (Datadog's Unified Service Tagging applies that label to every signal the
Agent collects from that pod, not just APM). That single tag is what keeps one student's
data from mixing into another's when many students each run their own Kind cluster but
all ship into the same Datadog org — which is why the two scripts (yours and theirs)
must agree on the exact same student name.

```bash
# Run once per student, using the exact identifier they sent you (the line their
# own script printed as "Using identifier: ..."), NOT their name retyped by hand —
# a re-typed name only matches if it slugifies to byte-for-byte the same string.
./observability/provision-student.sh jane-doe
```

Passing an already-slugified identifier like that works cleanly — `slugify()` is
idempotent on its own output, so `jane-doe` in gives `jane-doe` out. If you'd rather
type the student's actual name for a nicer-looking dashboard title, that's also fine —
just confirm the printed `Using identifier: ...` line matches what they gave you before
moving on, since that's the value that actually has to agree with their side.

This renders and `POST`s a titled, `env:workshop-jane-doe`-scoped copy of every
dashboard and monitor (rendered JSON + an id manifest land under
`observability/.provisioned/jane-doe/`, gitignored — keep it if you'll need the ids
later for cleanup or `PUT` updates). Order relative to the student's own script doesn't
matter, but their telemetry won't show up on their dashboards until both have run.

Pass a second argument to point a student's monitors at their own Slack handle instead
of the shared `@slack-workshop-alerts`: `./provision-student.sh jane-doe @slack-jane-alerts`.

**Nothing stops you from provisioning the same identifier twice** — there's no
collision check against past runs (same session, different day, different cohort). A
second run with the same slug creates a second full set of dashboards/monitors with the
identical title and, worse, the identical `env` tag as the first — meaning two different
students' telemetry would show up mixed together on shared queries. Keep track of who
you've provisioned; the script won't catch a repeat for you.

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

The exact `POST` commands for dashboards, monitors, and the log pipeline are in
**[Student Setup, step 4](#4-import-the-dashboards-monitors-and-log-pipeline-into-your-own-org)**
— that's the canonical copy; this section isn't repeating it to avoid the two drifting apart.

All three also import fine via the UI (**Dashboards > New Dashboard > Import Dashboard
JSON**, **Monitors > New Monitor > Import**, **Logs > Pipelines > New Pipeline**), or via
Terraform if you'd rather manage these as code for repeatability across attendee clusters.
