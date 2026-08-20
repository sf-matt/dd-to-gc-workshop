# Project context for Claude Code

This is a demo app for a live Datadog → groundcover Kubernetes migration
workshop. Keep changes small and workshop-friendly: no build systems beyond
`pip`/plain Dockerfiles, no databases unless explicitly asked for, no code
that requires SDK instrumentation (tracing is agentless by design — Datadog
Single Step Instrumentation + groundcover eBPF, both admission/kernel level,
not in-app).

## Structure

- `apps/order-api/` — Flask, calls `payment-svc` on `POST /order`
- `apps/payment-svc/` — Flask, has an in-memory chaos toggle at `POST /chaos`
  (`latency_ms`, `error_rate`) used to demo both dashboards reacting live
- `k8s/` — manifests for Kind. `workshop` namespace for the app,
  `datadog` namespace for the Agent (kept separate — Single Step
  Instrumentation doesn't instrument the Agent's own namespace)
- `observability/dashboard.json` + `observability/monitors.json` — Datadog
  dashboard/monitor definitions, importable via API or UI. These are the
  "before" state that gets rebuilt in groundcover during the workshop's
  migration half.

## Conventions to preserve when iterating

- Both services stay framework-vanilla Flask — no `ddtrace` or OTel SDK
  imports added directly to `app.py` unless we're deliberately testing the
  "dual-ship custom telemetry" stretch scenario (see prior workshop planning
  notes) — that's the one case where SDK instrumentation is intentional.
- `payment-svc`'s chaos state is in-memory and single-replica on purpose —
  don't add persistence or multi-replica support without discussing first,
  since that changes the live-demo mechanics.
- `load-generator` deliberately has no Dockerfile (`curlimages/curl` +
  inline shell loop) to minimize images to build/maintain. Only add a real
  Dockerfile for it if the traffic pattern needs to get more complex than a
  loop can express.
- Dashboard/monitor JSON should stay in sync with whatever the app emits —
  if you add a new endpoint or service, the corresponding widget/monitor
  should be added to `observability/` in the same change.
- If a database gets added later, prefer something with a Kind-friendly
  manifest (e.g. a single-replica Postgres Deployment + PVC) over anything
  requiring an operator — keep total workshop setup time in mind.

## Useful commands

```bash
# Local build, then load into the Kind cluster (no shared docker daemon)
docker build -t order-api:local apps/order-api
docker build -t payment-svc:local apps/payment-svc
kind load docker-image order-api:local --name workshop
kind load docker-image payment-svc:local --name workshop

# Redeploy after an app change
kubectl rollout restart deployment/order-api -n workshop
kubectl rollout restart deployment/payment-svc -n workshop

# Tail logs while iterating
kubectl logs -n workshop -l app=payment-svc -f

# Trigger chaos manually
kubectl port-forward -n workshop svc/payment-svc 5000:5000 &
curl -X POST http://localhost:5000/chaos -d '{"latency_ms": 800, "error_rate": 0.3}'
```
