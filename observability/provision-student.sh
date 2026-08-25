#!/usr/bin/env bash
# Provisions a student's copy of the workshop dashboards + monitors into the
# shared Datadog org, scoped to their own env tag so their data/alerts stay
# isolated from every other student's cluster.
#
# Usage:
#   ./provision-student.sh ["Student's Full Name"] [slack-handle]
#
# With no name argument, prompts interactively — there is no default, a name
# is always required. The name is slugified (lowercased, spaces/punctuation
# collapsed to single hyphens) for anything that has to be a queryable tag
# value (the env tag, the student: monitor tag) — this MUST produce the same
# slug as k8s/provision-student.sh for the same person, since both sides key
# off "workshop-<slug>". The full name as typed is still used for anything
# purely cosmetic (dashboard titles, monitor names).
#
# Example:
#   ./provision-student.sh "Jane Doe"                    -> env:workshop-jane-doe
#   ./provision-student.sh "Jane Doe" @slack-jane-alerts
#   ./provision-student.sh                                -> prompts for a name
#
# What this does NOT do: touch the student's own cluster. They still need to
# run k8s/provision-student.sh with the same name themselves.
set -euo pipefail

slugify() {
  # Must match k8s/provision-student.sh's slugify exactly — same input needs
  # to produce the same env tag on both sides.
  local input="$1" ascii
  if command -v iconv >/dev/null 2>&1; then
    ascii="$(printf '%s' "$input" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || true)"
  fi
  : "${ascii:=$input}"
  printf '%s' "$ascii" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-54 \
    | sed -E 's/-+$//'
}

if [ $# -ge 1 ]; then
  RAW_NAME="$1"
  SLACK_HANDLE="${2:-@slack-workshop-alerts}"
else
  read -r -p "Student's full name: " RAW_NAME || {
    echo "No input received (no terminal attached?) — pass the name as an argument instead: ./provision-student.sh \"Full Name\"" >&2
    exit 1
  }
  SLACK_HANDLE="@slack-workshop-alerts"
fi

if [ -z "${RAW_NAME//[[:space:]]/}" ]; then
  echo "A name is required — nothing was entered." >&2
  exit 1
fi

STUDENT="$(slugify "$RAW_NAME")"

if [ -z "$STUDENT" ]; then
  echo "'$RAW_NAME' has no usable characters after cleanup (letters/numbers only). Try again." >&2
  exit 1
fi

ENV_VALUE="workshop-${STUDENT}"

echo "Name entered: '${RAW_NAME}'"
echo "Using identifier: ${STUDENT}  (env: ${ENV_VALUE})"
if [ $# -lt 1 ]; then
  read -r -p "Look right? [Y/n] " CONFIRM || {
    echo "No input received (no terminal attached?) — nothing was provisioned." >&2
    exit 1
  }
  case "$CONFIRM" in
    [nN]*) echo "Aborted — re-run with the name you want." >&2; exit 1 ;;
  esac
fi
echo

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

echo "Provisioning workshop dashboards/monitors for '${RAW_NAME}'"
echo "  env tag:      ${ENV_VALUE}"
echo "  slack handle: ${SLACK_HANDLE}"
echo "  output dir:   ${OUT_DIR}"
echo

echo "== Dashboards =="
for f in observability/dashboards/*.json; do
  name=$(basename "$f")
  out="$OUT_DIR/$name"

  jq --arg name "$RAW_NAME" --arg env "$ENV_VALUE" '
    .title = .title + " — " + $name
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
jq --arg name "$RAW_NAME" --arg student "$STUDENT" --arg env "$ENV_VALUE" --arg slack "$SLACK_HANDLE" '
  map(
    .name = .name + " (" + $name + ")"
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
echo "The student needs to run, on their own machine:"
echo "  ./k8s/provision-student.sh \"${RAW_NAME}\""
echo "(or any input that slugifies to '${STUDENT}') so their env tag matches what's"
echo "provisioned here: ${ENV_VALUE}"
