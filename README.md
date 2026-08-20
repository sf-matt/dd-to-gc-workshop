# Datadog → groundcover Migration Workshop

A deliberately small two-service app used to demonstrate migrating a live
Kubernetes workload from Datadog to groundcover in one sitting. This repo
covers the **Datadog side**: the app, the Agent config, and the
dashboard/monitors to migrate. groundcover's migrating agent + BYOC setup is
handled separately (see the workshop invite for the pre-work guide).

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
observability/
  dashboard.json          # import into Datadog
  monitors.json           # import into Datadog
  README.md               # what backs each widget/monitor, and why
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

## Quick start (local / Kind)

```bash
kind create cluster --config kind-config.yaml

# Build images normally, then load them into the Kind cluster
docker build -t order-api:local apps/order-api
docker build -t payment-svc:local apps/payment-svc
kind load docker-image order-api:local --name workshop
kind load docker-image payment-svc:local --name workshop

# Namespaces
kubectl apply -f k8s/00-namespace.yaml

# Datadog Operator + Agent (adjust to however you already install the Operator)
kubectl create secret generic datadog-secret \
  --from-literal api-key=<YOUR_DD_API_KEY> -n datadog
kubectl apply -f k8s/datadog-agent.yaml

# App
kubectl apply -f k8s/10-payment-svc.yaml
kubectl apply -f k8s/20-order-api.yaml
kubectl apply -f k8s/30-load-generator.yaml
```

Give it a couple of minutes, then check APM > Traces in Datadog for
`order-api` and `payment-svc` — traffic should already be flowing from
`load-generator`.

## Running the chaos demo

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

Watch the Latency and Error Rate widgets on the imported dashboard react
within a minute — that's the same moment you'll reproduce in groundcover
during the migration half of the workshop.

## Resetting between sessions

Kind makes this cheap — for a full reset (e.g. rehearsing multiple times, or
between workshop cohorts):

```bash
kind delete cluster --name workshop
```

then re-run the quick start from the top. For a lighter reset that keeps the
Agent/groundcover installed and only resets the app:

```bash
kubectl delete namespace workshop
kubectl apply -f k8s/00-namespace.yaml -f k8s/10-payment-svc.yaml \
  -f k8s/20-order-api.yaml -f k8s/30-load-generator.yaml
```

## Next: observability

See `observability/README.md` for the dashboard/monitor import steps and the
exact metrics backing each widget.
