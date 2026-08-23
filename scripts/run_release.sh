#!/usr/bin/env bash
# The release itself. Normal runs submit a release, poll until the report is
# ready, and write it into the report folder. When fetch_only_release_id is
# set, nothing is submitted: the named release's report is fetched and
# written exactly like a normal run's.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ "$(state_get mode)" = "sync" ]; then
  echo "mode is sync; nothing is submitted on this job."
  exit 0
fi

timeout="$(state_get poll_timeout_minutes)"
[ -n "$timeout" ] || timeout=45
api_base="$(state_get api_base)"
fetch_only="$(state_get fetch_only)"

if [ -n "$fetch_only" ]; then
  id="$fetch_only"
  echo "fetch_only_release_id is set: fetching the report for $id. Nothing is submitted this run."
  status_file="$(state_dir)/status.json"
  code="$(api_get "/v1/releases/$id" "$status_file")"
  if [ "$code" != "200" ]; then
    echo "::error::GET /v1/releases/$id returned HTTP $code"
    print_error_body "$status_file"
    exit 1
  fi
  status="$(jq -r '.status // "unknown"' "$status_file")"
  release_date="$(jq -r '.received_at // empty' "$status_file" | cut -c1-10)"
  [ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"
  case "$status" in
    report_ready|corrected)
      ;;
    failed)
      failure="$(jq -r '.failure // "(no failure field on the status body)"' "$status_file")"
      echo "::error::release $id failed on the Verging side: $failure"
      echo "The release is voided; voided tests are never billed. Start a new release, or send Verging the release_id."
      exit 1
      ;;
    *)
      echo "Release $id is not finished yet (status: $status); waiting for the report."
      poll_release "$id" "$timeout"
      ;;
  esac
  fetch_and_write "$id" "$release_date"
  exit 0
fi

# Normal run: submit the release (POST /v1/releases).
vendor_version="$(state_get vendor_version)"
endpoint="$(state_get endpoint)"
environment="$(state_get environment)"
suites_json="$(state_get suites_json)"
product_name="$(state_get product_name)"

args=(--arg vendor_version "$vendor_version" --arg endpoint "$endpoint" --arg environment "$environment")
filter='{vendor_version: $vendor_version, endpoint: $endpoint, environment: $environment}'
if [ -n "$suites_json" ]; then
  args+=(--argjson suites "$suites_json")
  filter="$filter + {suites: \$suites}"
else
  echo "No suites selected: this release is Full Coverage (every test suite)."
fi
if [ -n "$product_name" ]; then
  args+=(--arg product_name "$product_name")
  filter="$filter + {product_name: \$product_name}"
fi
body="$(jq -cn "${args[@]}" "$filter")"
echo "POST $api_base/v1/releases"
echo "Request body: $body"

receipt="$(state_dir)/receipt.json"
code="$(curl -sS -o "$receipt" -w '%{http_code}' \
  -X POST "$api_base/v1/releases" \
  -H "Authorization: Bearer ${VERGING_API_KEY:?VERGING_API_KEY is not set}" \
  -H "Content-Type: application/json" \
  -d "$body")" || code="000"

if [ "$code" != "202" ]; then
  echo "::error::POST /v1/releases returned HTTP $code (expected 202)"
  print_error_body "$receipt"
  {
    echo "## Verging Memory CI: release not accepted"
    echo
    echo "POST /v1/releases returned HTTP $code."
    echo
    echo '```'
    cat "$receipt" 2>/dev/null || true
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi

release_id="$(jq -r '.release_id // empty' "$receipt")"
if [ -z "$release_id" ]; then
  echo "::error::the receipt carries no release_id"
  cat "$receipt"
  exit 1
fi

echo "Receipt (HTTP 202):"
jq -r '
  "  release_id:     \(.release_id)",
  "  received_at:    \(.received_at // "(not given)")",
  "  status:         \(.status // "(receipt carries no status field; queued per the 202)")",
  "  scope:          \(if .scope == null then "null (Full Coverage)" else (.scope | tojson) end)",
  "  scope_summary:  \(.scope_summary // "(not given)")",
  "  status_url:     \(.status_url // "(not given)")",
  "  message:        \(.message // "(not given)")"
' "$receipt"
echo "If this run stops before the report is committed, re-run with fetch_only_release_id=$release_id to fetch and commit it without submitting again."

release_date="$(jq -r '.received_at // empty' "$receipt" | cut -c1-10)"
[ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"
state_set release_id "$release_id"
state_set release_date "$release_date"

{
  echo "## Verging Memory CI"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| vendor_version | \`$vendor_version\` |"
  echo "| environment | \`$environment\` |"
  echo "| release_id | \`$release_id\` |"
  echo "| received_at | $(jq -r '.received_at // "(not given)"' "$receipt") |"
  echo "| scope | \`$(jq -c '.scope' "$receipt")\` |"
  echo "| scope_summary | $(jq -r '.scope_summary // "(not given)"' "$receipt") |"
  echo
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

poll_release "$release_id" "$timeout"
fetch_and_write "$release_id" "$release_date"
