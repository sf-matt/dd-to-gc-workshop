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

**Confirmed working**: this exact command (`values.yaml` + `.env`-sourced token) has been
run against this workshop's Kind cluster — `kubectl get pods -n groundcover` shows the
sensor DaemonSet, Vector, kube-state-metrics, and metrics-ingester all healthy, and the
sensor's own logs show eBPF probes attaching successfully and profile uploads to
groundcover succeeding. See the caveat in **Dual-shipping**'s step 3 below, though: sensor
health doesn't by itself confirm this workshop's telemetry is actually *findable* on the
groundcover side under the expected `clusterId` — that part is still open.

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

### 1. The additional-endpoints env vars are already in `k8s/datadog-agent.yaml`

```yaml
  override:
    nodeAgent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DD_APM_ADDITIONAL_ENDPOINTS
          value: '{"http://groundcover-sensor.groundcover.svc.cluster.local:8126": ["GROUNDCOVER_TOKEN_PLACEHOLDER"]}'
        - name: DD_ADDITIONAL_ENDPOINTS
          value: '{"http://groundcover-sensor.groundcover.svc.cluster.local:8126/datadog": ["GROUNDCOVER_TOKEN_PLACEHOLDER"]}'
```

`GROUNDCOVER_TOKEN_PLACEHOLDER` is not a real value — it's substituted with the real
ingestion token from `.env`'s `GROUNDCOVER_TOKEN` at apply time (step 2), the same
`.env`-sourced pattern as everything else in this repo. **Never replace it directly in
the committed file** — that would put a real credential in git.

Two things to get exactly right if you're changing this by hand:
- **The `/datadog` suffix is only on `DD_ADDITIONAL_ENDPOINTS`** (the metrics one) — not on
  `DD_APM_ADDITIONAL_ENDPOINTS` (traces). Different paths on the same receiver.
- The `groundcover-sensor.groundcover.svc.cluster.local` hostname assumes groundcover was
  installed with its default Helm release/namespace (`groundcover`). If yours differs,
  swap in the actual `<service>.<namespace>.svc.cluster.local` for your install.

(groundcover's own Kubernetes-environment docs for this path say the ingestion key isn't
actually checked by the sensor's receiver — a literal placeholder string works. This
workshop uses the real token anyway, since it costs nothing and matches how every other
credential here is handled — never a hardcoded placeholder sitting in committed YAML.)

### 2. Apply it

```bash
source .env   # needs GROUNDCOVER_TOKEN set
sed "s/GROUNDCOVER_TOKEN_PLACEHOLDER/${GROUNDCOVER_TOKEN}/g" k8s/datadog-agent.yaml | kubectl apply -f -
```

Same substitute-before-apply pattern as the `site:` fix in `observability/README.md` —
the real token only ever exists in your shell's environment and in the live cluster,
never written to a file that could end up in git.

The Datadog Operator reconciles the `DatadogAgent` CR and rolls the `datadog-agent`
DaemonSet automatically on spec changes — no separate `rollout restart` needed (verified
earlier in this workshop's own setup: editing this same CR's `site` field triggered an
automatic rollout without any extra command).

### 3. Verify

**Confirmed working on the Agent side**: applying this rolls a fresh `datadog-agent` pod
cleanly (`3/3` ready), the real token lands in its environment, and neither the core
agent nor trace-agent log any groundcover-related errors — dual-shipping is configured
and sending without complaint.

**Not yet confirmed on the receiving side.** Looking for the actual `order-api`/
`payment-svc` data in groundcover hit a real, unresolved mystery: querying the
`experiments` tenant for `clusterId: matt_workshop` (the value this workshop's
`groundcover/values.yaml` sets, confirmed applied via `helm get values`) returns nothing,
even several minutes after the sensor came up healthy. The only cluster names visible in
that tenant don't match this Kind cluster's actual workloads. So: the Agent believes
it's shipping successfully, but end-to-end proof that groundcover received and stored
that data is still open. Don't treat this as confirmed working until someone resolves
that and actually finds the data on the groundcover side.

Sources for the config itself (not the open receiving-side question above):
- [Shipping from the DataDog Agent — groundcover docs](https://docs.groundcover.com/integrations/data-sources/datadog/shipping-from-the-datadog-agent)
- [Sending Directly from Instrumented Services — groundcover docs](https://docs.groundcover.com/integrations/data-sources/datadog/sending-directly-from-instrumented-services)
- [Dual Shipping — Datadog docs](https://docs.datadoghq.com/agent/configuration/dual-shipping/)
