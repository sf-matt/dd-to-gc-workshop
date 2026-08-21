#!/usr/bin/env bash
# Renders a student's copy of the app manifests, tagged with their own env
# value, so their telemetry lands under env:workshop-<name> and stays
# isolated from every other student's cluster in the shared Datadog org.
# Pairs with observability/provision-student.sh, which provisions that same
# student's dashboards/monitors scoped to the identical env tag.
#
# This does NOT touch any live cluster — it only writes rendered YAML.
# Each student runs this against their own checkout, on their own machine,
# against their own Kind cluster.
#
# Usage:
#   ./provision-student.sh <student-name>
#
# Example:
#   ./provision-student.sh alice
set -euo pipefail

STUDENT="${1:?Usage: provision-student.sh <student-name>}"
ENV_VALUE="workshop-${STUDENT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="k8s/.provisioned/${STUDENT}"
mkdir -p "$OUT_DIR"

echo "Provisioning k8s manifests for student '${STUDENT}' (env: ${ENV_VALUE})"
echo "  output dir: ${OUT_DIR}"
echo

echo "== Tagged manifests =="
for f in k8s/10-payment-svc.yaml k8s/20-order-api.yaml; do
  name=$(basename "$f")
  out="$OUT_DIR/$name"
  sed "s|tags.datadoghq.com/env: \"workshop\"|tags.datadoghq.com/env: \"${ENV_VALUE}\"|g" "$f" > "$out"

  before=$(grep -c 'tags.datadoghq.com/env: "workshop"' "$f" || true)
  after=$(grep -c "tags.datadoghq.com/env: \"${ENV_VALUE}\"" "$out" || true)
  if [ "$before" -eq 0 ] || [ "$before" -ne "$after" ]; then
    echo "  WARNING: $name — expected $before env-label substitution(s), made $after. Check the file." >&2
  fi
  echo "  rendered $name ($after env-label substitution(s))"
done

echo
echo "== Unchanged manifests (copied through for a single apply-able directory) =="
for f in k8s/00-namespace.yaml k8s/30-load-generator.yaml; do
  name=$(basename "$f")
  cp "$f" "$OUT_DIR/$name"
  echo "  copied $name"
done

echo
echo "== Validating rendered YAML (client-side only, no cluster contacted) =="
if command -v kubectl >/dev/null 2>&1; then
  kubectl apply --dry-run=client -f "$OUT_DIR" -o name
else
  echo "  kubectl not found — skipping validation, review the YAML by hand." >&2
fi

echo
echo "Done. Rendered manifests saved under ${OUT_DIR}/"
echo
echo "${STUDENT} should build/load images and apply from that directory, e.g.:"
echo
echo "  docker build -t order-api:local apps/order-api"
echo "  docker build -t payment-svc:local apps/payment-svc"
echo "  kind load docker-image order-api:local --name workshop"
echo "  kind load docker-image payment-svc:local --name workshop"
echo "  kubectl apply -f ${OUT_DIR}/"
echo
echo "Datadog side: run ./observability/provision-student.sh ${STUDENT} first (or after —"
echo "order doesn't matter) so the dashboards/monitors expecting env:${ENV_VALUE} already exist."
