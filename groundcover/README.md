# DD → GC Workshop: groundcover Side

This covers the groundcover half of the migration — the piece `observability/README.md`'s
Datadog dashboards/monitors get rebuilt into. Sensor install and dashboard/monitor parity
instructions land here as they're verified.

## Installing the sensor

Sensor-only mode (`global.backend.enabled: false`) — the sensor ships data to groundcover's
managed backend rather than running its own, which is what you want unless you were
specifically told to self-host the backend too.

**1. Add the token to `.env`:**

```bash
# .env — get the value from `groundcover auth get-ingestion-key sensor`, or your
# groundcover account's Settings > Ingestion Keys
GROUNDCOVER_TOKEN=<your sensor ingestion token>
source .env
```

`groundcover/values.yaml` deliberately leaves `global.groundcover_token` empty and stays
safe to commit — the real value is injected at install time via `--set` below, never
written to a file that could end up in git. Same pattern as `DD_API_KEY` elsewhere in
this repo.

**2. Install:**

```bash
helm repo add groundcover https://helm.groundcover.com
helm repo update groundcover

helm upgrade groundcover groundcover/groundcover \
  -i --create-namespace -n groundcover \
  -f groundcover/values.yaml \
  --set global.groundcover_token="$GROUNDCOVER_TOKEN"
```

`-i` is `--install` (creates the release if it doesn't exist yet, upgrades in place if it
does — the same command works for both first install and later config changes).
`--set` after `-f` wins on conflicts, so the real token from `.env` overrides the empty
one in the values file without ever needing to edit that file.

**3. Verify:**

```bash
kubectl get pods -n groundcover
```

groundcover's own docs note `clusterId` (here: `matt_workshop`) and `env` (here: `dev`)
are both optional — `clusterId` is auto-detected from the cluster if omitted, `env` just
organizes clusters in groundcover's Cluster Picker UI if set. Neither blocks a fresh
install if left out; they're set explicitly here for a predictable, findable name instead
of whatever auto-detection would have picked.

**Not yet empirically tested against a real cluster in this repo** — same caveat as
dual-shipping below: this is sourced directly from groundcover's own install docs, not
verified live here the way the Datadog-side setup was. The values file matches exactly
what was provided for this workshop's sensor-only setup, but the full install hasn't
been run end-to-end yet.

Sources:
- [Connect Kubernetes clusters — groundcover docs](https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster)
- [Deploying in Sensor-Only mode — groundcover docs](https://docs.groundcover.com/architecture/byoc/deploying-in-sensor-only-mode)
- [groundcover Helm Charts](https://helm.groundcover.com/)

## Dual-shipping from the Datadog Agent

Sends a **copy** of traces, APM metrics, and DogStatsD custom metrics to groundcover
while the Agent keeps shipping to Datadog normally — nothing about the existing
Datadog-side setup changes or stops working. This is Datadog's own native dual-shipping
mechanism (`additional_endpoints`), pointed at a Datadog-trace-protocol-compatible
receiver groundcover's sensor exposes for exactly this purpose.

**Prerequisite: the groundcover sensor must already be deployed in this cluster** — see
**Installing the sensor** above. Until it's running, the hostname below won't resolve
and the Agent will just log connection warnings for the additional endpoint — it won't
break the existing Datadog shipping, but it won't be sending groundcover anything either.

**What this does *not* cover:** logs. groundcover's own documentation for this path only
mentions traces, APM metrics, and custom metrics — there's no equivalent
`DD_LOGS_CONFIG_ADDITIONAL_ENDPOINTS` step documented, so don't assume logs are dual-shipping
just because this is configured.

### 1. Add the additional-endpoints env vars

Edit `k8s/datadog-agent.yaml` — add these two entries to the existing
`spec.override.nodeAgent.env` list, alongside the existing `DD_HOSTNAME` entry:

```yaml
  override:
    nodeAgent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DD_APM_ADDITIONAL_ENDPOINTS
          value: '{"http://groundcover-sensor.groundcover.svc.cluster.local:8126": ["groundcover-nokeyneeded"]}'
        - name: DD_ADDITIONAL_ENDPOINTS
          value: '{"http://groundcover-sensor.groundcover.svc.cluster.local:8126/datadog": ["groundcover-nokeyneeded"]}'
```

Two things to get exactly right:
- **The `/datadog` suffix is only on `DD_ADDITIONAL_ENDPOINTS`** (the metrics one) — not on
  `DD_APM_ADDITIONAL_ENDPOINTS` (traces). Different paths on the same receiver.
- **`"groundcover-nokeyneeded"` is literal**, not a placeholder to replace — groundcover's
  receiver doesn't check it, but the field can't be empty.

The `groundcover-sensor.groundcover.svc.cluster.local` hostname assumes groundcover was
installed with its default Helm release/namespace (`groundcover`). If yours differs,
swap in the actual `<service>.<namespace>.svc.cluster.local` for your install.

### 2. Apply it

```bash
kubectl apply -f k8s/datadog-agent.yaml
```

The Datadog Operator reconciles the `DatadogAgent` CR and rolls the `datadog-agent`
DaemonSet automatically on spec changes — no separate `rollout restart` needed (verified
earlier in this workshop's own setup: editing this same CR's `site` field triggered an
automatic rollout without any extra command).

### 3. Verify

Once the sensor's up and this is applied, the same `order-api`/`payment-svc` traces this
workshop already generates should show up on both sides simultaneously — check APM in
Datadog as usual, and look for the same services in groundcover. This hasn't been tested
against a real cluster yet in this repo — the config is sourced directly from groundcover's
own docs (linked below), not empirically verified here the way the rest of this workshop's
Datadog-side config was. Treat it as a documented starting point, not a proven one, until
someone runs it against a live sensor.

Sources:
- [Shipping from the DataDog Agent — groundcover docs](https://docs.groundcover.com/integrations/data-sources/datadog/shipping-from-the-datadog-agent)
- [Sending Directly from Instrumented Services — groundcover docs](https://docs.groundcover.com/integrations/data-sources/datadog/sending-directly-from-instrumented-services)
- [Dual Shipping — Datadog docs](https://docs.datadoghq.com/agent/configuration/dual-shipping/)
