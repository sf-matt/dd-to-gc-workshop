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
#   ./provision-student.sh ["Your Full Name"]
#
# With no argument, prompts interactively — there is no default, a name is
# always required. The name is slugified (lowercased, spaces/punctuation
# collapsed to single hyphens) before use, because it ends up as a
# Kubernetes label *value* on the app Deployments (tags.datadoghq.com/env),
# and label values cannot contain spaces or most punctuation.
#
# Example:
#   ./provision-student.sh "Jane Doe"     -> env:workshop-jane-doe
#   ./provision-student.sh                -> prompts for a name
set -euo pipefail

slugify() {
  # Transliterate accented Latin letters to ASCII where possible (José ->
  # Jose) before the strict cleanup, so non-English names degrade gracefully
  # instead of losing letters. Names outside Latin script (e.g. CJK) still
  # end up empty and hit the "no usable characters" check below — this only
  # handles the common Latin-with-diacritics case, not full transliteration.
  local input="$1" ascii
  if command -v iconv >/dev/null 2>&1; then
    ascii="$(printf '%s' "$input" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || true)"
  fi
  : "${ascii:=$input}"
  # lowercase, collapse any run of non-alphanumeric chars to one hyphen,
  # trim leading/trailing hyphens, cap length so "workshop-<slug>" stays
  # within Kubernetes' 63-char label-value limit (63 - len("workshop-") = 54)
  printf '%s' "$ascii" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-54 \
    | sed -E 's/-+$//'
}

if [ $# -ge 1 ]; then
  RAW_NAME="$1"
else
  read -r -p "Enter your full name: " RAW_NAME || {
    echo "No input received (no terminal attached?) — pass your name as an argument instead: ./provision-student.sh \"Your Name\"" >&2
    exit 1
  }
fi

if [ -z "${RAW_NAME//[[:space:]]/}" ]; then
  echo "A name is required — nothing was entered." >&2
  exit 1
fi

STUDENT="$(slugify "$RAW_NAME")"

if [ -z "$STUDENT" ]; then
  echo "'$RAW_NAME' has no usable characters after cleanup (letters/numbers only). Try again with your name." >&2
  exit 1
fi

ENV_VALUE="workshop-${STUDENT}"

echo "Name entered: '${RAW_NAME}'"
echo "Using identifier: ${STUDENT}  (env: ${ENV_VALUE})"
read -r -p "Look right? [Y/n] " CONFIRM || {
  echo "No input received (no terminal attached?) — nothing was provisioned." >&2
  exit 1
}
case "$CONFIRM" in
  [nN]*) echo "Aborted — re-run with the name you want." >&2; exit 1 ;;
esac
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="k8s/.provisioned/${STUDENT}"
mkdir -p "$OUT_DIR"

echo "Provisioning k8s manifests for '${RAW_NAME}' (env: ${ENV_VALUE})"
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
echo "== Validating rendered YAML =="
# Pinned to the kind-workshop context explicitly: "kubectl apply --dry-run=client"
# still queries the live API server for each object's current state (that's how
# it knows what would change) — it just stops short of submitting the write. Left
# to whatever context happens to be active, that's a real query against a cluster
# this script has no business touching. If kind-workshop doesn't exist yet (e.g.
# you haven't run `kind create cluster` yet), skip validation rather than fall
# back to some other context.
if ! command -v kubectl >/dev/null 2>&1; then
  echo "  kubectl not found — skipping validation, review the YAML by hand." >&2
elif ! kubectl config get-contexts kind-workshop >/dev/null 2>&1; then
  echo "  kind-workshop context not found (cluster not created yet?) — skipping" \
       "validation. Run this again after 'kind create cluster' if you want it checked." >&2
else
  kubectl --context kind-workshop apply --dry-run=client -f "$OUT_DIR" -o name
fi

echo
echo "Done. Rendered manifests saved under ${OUT_DIR}/"
echo
echo "Build/load images and apply from that directory, e.g.:"
echo
echo "  docker build -t order-api:local apps/order-api"
echo "  docker build -t payment-svc:local apps/payment-svc"
echo "  kind load docker-image order-api:local --name workshop"
echo "  kind load docker-image payment-svc:local --name workshop"
echo "  kubectl apply -f ${OUT_DIR}/"
echo
echo "Datadog side: your instructor needs to run"
echo "  ./observability/provision-student.sh \"${RAW_NAME}\""
echo "(or any input that slugifies to '${STUDENT}') so the dashboards/monitors expecting"
echo "env:${ENV_VALUE} already exist. Order doesn't matter, but you need both."
