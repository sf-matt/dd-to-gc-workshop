#!/usr/bin/env bash
# Provisions a student's copy of the workshop dashboards + monitors into the
# shared Datadog org, scoped to their own env tag so their data/alerts stay
# isolated from every other student's cluster.
#
# Usage:
#   ./provision-student.sh <student-name> [slack-handle]
#
# Example:
#   ./provision-student.sh alice
#   ./provision-student.sh bob @slack-bob-alerts
#
# What this does NOT do: touch the student's own cluster. They still need to
# set tags.datadoghq.com/env to the same value (printed at the end) on their
# order-api and payment-svc Deployments before redeploying.
set -euo pipefail

STUDENT="${1:?Usage: provision-student.sh <student-name> [slack-handle]}"
SLACK_HANDLE="${2:-@slack-workshop-alerts}"
ENV_VALUE="workshop-${STUDENT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -f .env ]; then
  echo "Missing .env at repo root (copy .env.example and fill in DD_API_KEY/DD_APP_KEY/DD_SITE)." >&2
  exit 1
fi
source .env

OUT_DIR="observability/.provisioned/${STUDENT}"
mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/manifest.jsonl"
: > "$MANIFEST"

echo "Provisioning workshop dashboards/monitors for student '${STUDENT}'"
echo "  env tag:      ${ENV_VALUE}"
echo "  slack handle: ${SLACK_HANDLE}"
echo "  output dir:   ${OUT_DIR}"
echo

echo "== Dashboards =="
for f in observability/dashboards/*.json; do
  name=$(basename "$f")
  out="$OUT_DIR/$name"

  jq --arg student "$STUDENT" --arg env "$ENV_VALUE" '
    .title = .title + " — " + $student
    | .template_variables = (
        (.template_variables // []) | map(
          if .name == "env" then . + {default: $env, available_values: [$env]}
          else . end
        )
      )
  ' "$f" > "$out"

  resp=$(curl -s -X POST "https://api.${DD_SITE}/api/v1/dashboard" \
    -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" -d @"$out")
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then
    echo "  FAILED  $name: $(echo "$resp" | jq -c '.errors // .')" >&2
    continue
  fi
  title=$(echo "$resp" | jq -r '.title')
  echo "  created $name -> id=$id ($title)"
  jq -nc --arg type dashboard --arg file "$name" --arg id "$id" --arg title "$title" \
    '{type: $type, file: $file, id: $id, title: $title}' >> "$MANIFEST"
done

echo
echo "== Monitors =="
rendered_monitors="$OUT_DIR/monitors.json"
jq --arg student "$STUDENT" --arg env "$ENV_VALUE" --arg slack "$SLACK_HANDLE" '
  map(
    .name = .name + " (" + $student + ")"
    | .query = (.query | gsub("env:workshop"; "env:" + $env))
    | .tags = ((.tags // []) + ["student:" + $student])
    | .message = (.message | gsub("@slack-workshop-alerts"; $slack))
  )
' observability/monitors.json > "$rendered_monitors"

jq -c '.[]' "$rendered_monitors" | while read -r monitor; do
  name=$(echo "$monitor" | jq -r '.name')
  resp=$(echo "$monitor" | curl -s -X POST "https://api.${DD_SITE}/api/v1/monitor" \
    -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" -d @-)
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then
    echo "  FAILED  $name: $(echo "$resp" | jq -c '.errors // .')" >&2
    continue
  fi
  echo "  created $name -> id=$id"
  jq -nc --arg type monitor --arg name "$name" --arg id "$id" \
    '{type: $type, name: $name, id: $id}' >> "$MANIFEST"
done

echo
echo "Done. Rendered JSON + id manifest saved under ${OUT_DIR}/"
echo
echo "One more step on the student's own machine — set the same env tag on both"
echo "app Deployments before they deploy (k8s/10-payment-svc.yaml, k8s/20-order-api.yaml):"
echo
echo "  tags.datadoghq.com/env: \"${ENV_VALUE}\""
echo
echo "(appears twice per file: metadata.labels and spec.template.metadata.labels)"
