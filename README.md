# Datadog → groundcover Migration Workshop

A deliberately small two-service app used to demonstrate migrating a live
Kubernetes workload from Datadog to groundcover in one sitting. `observability/`
covers the Datadog side: the app, the Agent config, and the dashboards/monitors
to migrate. `groundcover/` covers the migration itself — dual-shipping,
sensor install, and rebuilding the same dashboards/monitors in groundcover —
and is filled in as each piece gets verified.

> **Attending the workshop?** Skip straight to
> [**Student Setup**](observability/README.md#student-setup) — copy-paste
> commands for both "your own Datadog trial" and "shared lab" setups. The
> rest of this file is background for whoever's running the workshop.

## What's here

```
apps/
  order-api/     # receives POST /order, calls payment-svc
  payment-svc/   # processes the "charge", has a live chaos toggle
k8s/
  00-namespace.yaml       # `workshop` (app) + `datadog` (Agent) namespaces
  10-payment-svc.yaml
  20-order-api.yaml
  30-load-generator.yaml  # constant traffic generator, no custom image needed
  datadog-agent.yaml      # DatadogAgent CR: hostname fix, kubelet TLS fix, SSI
  provision-student.sh    # renders per-student, env-tagged copies of the app manifests
observability/
  dashboards/*.json       # 5 standalone dashboards, import into Datadog
  monitors.json           # 9 monitors, import into Datadog
  log-pipeline.json       # log processing pipeline (HTTP status -> log severity)
  provision-student.sh    # renders + imports a per-student copy of the above
  README.md               # what backs each widget/monitor, and why
groundcover/
  README.md               # the migration itself: sensor install, dual-shipping, dashboard/monitor parity
  values.yaml             # sensor-only Helm values (token injected from .env at install time)
scripts/
  chaos-load-test.sh      # cycles payment-svc through baseline/latency/errors/both/recovery
```

## Why it's shaped this way

- **No code touches Datadog or groundcover.** Tracing comes from Datadog
  Single Step Instrumentation (admission-controller injected) and
  groundcover's eBPF sensor — both agentless from the app's point of view.
  `app.py` in both services is plain Flask.
- **The chaos toggle is the demo engine.** `POST /chaos` on payment-svc lets
  you dial in latency and/or error rate live, so both dashboards move in real
  time in front of the room instead of you narrating static graphs.
- **`load-generator` needs no build.** It's `curlimages/curl` with a shell
  loop in the manifest — one less image to maintain.

## Prerequisites & Quick start

Both live in **[`observability/README.md`, Student Setup](observability/README.md#student-setup)**
— that's the canonical, complete copy (CLIs, cluster/Agent bring-up, dashboard/monitor
import, and two things worth knowing before you run it: a real site-mismatch trap
between `.env` and `k8s/datadog-agent.yaml`, and Datadog's own auto-generated
Recommended Monitors). This file doesn't keep a second copy, so the two can't drift
apart the way they already did once this session.

## Running the chaos demo

For a single live moment (narrating in front of a room):

```bash
kubectl port-forward -n workshop svc/payment-svc 5000:5000

# Inject latency + a 30% error rate
curl -X POST http://localhost:5000/chaos \
  -H 'Content-Type: application/json' \
  -d '{"latency_ms": 800, "error_rate": 0.3}'

# Reset
curl -X POST http://localhost:5000/chaos \
  -H 'Content-Type: application/json' \
  -d '{"latency_ms": 0, "error_rate": 0.0}'
```

For generating a full spread of data unattended (populating dashboards/monitors before a
demo, or testing that alerts actually fire — this is scripted version of exactly the
manual steps above, cycled through baseline/latency/errors/both/recovery automatically):

```bash
./scripts/chaos-load-test.sh
# PHASE_SECONDS=360 ./scripts/chaos-load-test.sh   # 300s+ recommended so 5-minute
                                                    # rolling-window monitors have
                                                    # time to actually cross threshold
```

Safe to `Ctrl-C` at any point — always reverts chaos to baseline on exit, so you can't
walk away and leave it running.

Watch the Latency and Error Rate widgets on the imported dashboard react
within a minute — that's the same moment you'll reproduce in groundcover
during the migration half of the workshop.

## Resetting between sessions

Kind makes this cheap — for a full reset (e.g. rehearsing multiple times, or
between workshop cohorts):

```bash
kind delete cluster --name workshop
```

then re-run [Student Setup](observability/README.md#student-setup) from the top. For a
lighter reset that keeps the Datadog Agent (and groundcover's sensor, if you've also
installed it — see `groundcover/README.md`) and only resets the app:

```bash
kubectl delete namespace workshop
kubectl apply -f k8s/00-namespace.yaml -f k8s/10-payment-svc.yaml \
  -f k8s/20-order-api.yaml -f k8s/30-load-generator.yaml
```

## Next

- `observability/README.md` — dashboard/monitor import steps and the exact
  metrics backing each widget (the Datadog "before" state).
- `groundcover/README.md` — the migration itself: dual-shipping from the
  Datadog Agent, sensor install, and rebuilding the same dashboards/monitors
  in groundcover for the parity comparison.
