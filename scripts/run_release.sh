#!/usr/bin/env bash
# The release itself. Normal runs submit a release, poll until the report is
# ready, and write it into the report folder. The release goes on record as
# pending (releases/pending.json) the moment it is accepted; when the deadline
# passes before the report is ready the job ends green with the verdict
# "Pending", and the reconcile pass of a later job collects the report. When
# fetch_only_release_id is set, nothing is submitted: the named release's
# report is fetched and written exactly like a normal run's. When
# wiring_check is true, or when the API refuses the release with HTTP 409 and
# code "not_set_up" (the test suites are not set up on the agent setups yet),
# the free wiring check is submitted instead, its page is written like a
# report, and the run passes.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

# In sync mode nothing is submitted: the reconcile pass has already collected
# any reports now ready. action.yml skips this step in sync mode; this guard
# makes the script a safe no-op even if it is invoked directly.
if [ "$(state_get mode)" = "sync" ]; then
  echo "mode sync: nothing is submitted; the reconcile pass collected any reports now ready for the releases on record."
  exit 0
fi

timeout="$(state_get poll_timeout_minutes)"
[ -n "$timeout" ] || timeout=45
api_base="$(state_get api_base)"
folder="$(state_get folder)"
fetch_only="$(state_get fetch_only)"

# wait_for_report RELEASE_ID: poll until the report is ready, then return 0.
# When the deadline passes first the release stays on record as pending, the
# job ends green (exit 0 from here), and when the release failed on the
# Verging side the entry is cleared and the job ends red (exit 1 from here).
wait_for_report() {
  local id="$1" rc
  poll_release "$id" "$timeout" && rc=0 || rc=$?
  case "$rc" in
    0) pending_set_status "$folder" "$id" "$(state_get last_status)"; return 0 ;;
    2) stop_waiting "$id" "$(state_get last_status)"; exit 0 ;;
    *) pending_clear "$folder" "$id"; exit 1 ;;
  esac
}

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
      echo "The release is voided; voided tests are never billed. Start a new release, or send the release_id to contact@verginglabs.com."
      exit 1
      ;;
    *)
      echo "Release $id is not finished yet (status: $status); waiting for the report."
      # Put the release on record as pending from its status body, unless it
      # is already there, so a job that stops waiting leaves it for the next.
      if [ -z "$(pending_get "$folder" "$id")" ]; then
        pending_set "$folder" "$id" "$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
          vendor_version: (.vendor_version // "not-recorded"),
          environments: (.environments.agent_setups // []),
          submitted_at: (.received_at // $now),
          status: (.status // "unknown")}' "$status_file")"
      fi
      wait_for_report "$id"
      ;;
  esac
  fetch_and_write "$id" "$release_date"
  exit 0
fi

# Normal run: submit the release (POST /v1/releases).
vendor_version="$(state_get vendor_version)"
environments_json="$(state_get environments_json)"
suites_json="$(state_get suites_json)"
product_name="$(state_get product_name)"

args=(--arg vendor_version "$vendor_version")
filter='{vendor_version: $vendor_version}'
# The agent setup(s): the `environments` array (parity with the API), one name
# or several. resolve_inputs.sh has already ensured it is set and non-empty.
args+=(--argjson environments "$environments_json")
filter="$filter + {environments: \$environments}"
if [ -n "$suites_json" ]; then
  args+=(--argjson suites "$suites_json")
  filter="$filter + {suites: \$suites}"
else
  echo "No suites selected: this release runs all the suites chosen for your account and set up on every named agent setup."
fi
if [ -n "$product_name" ]; then
  args+=(--arg product_name "$product_name")
  filter="$filter + {product_name: \$product_name}"
fi
body="$(jq -cn "${args[@]}" "$filter")"

# submit_wiring_check BODY WHY: POST the same request with wiring_check: true,
# then fetch its page and write it into the report folder like a report. WHY
# is "input" (the wiring_check input) or "not_set_up" (the release was refused
# because the suites are not set up yet); the surfaces and the closing notice
# read it. A wiring check is served on delivery, so nothing is polled.
submit_wiring_check() {
  local body="$1" why="$2" wbody receipt code release_id release_date
  wbody="$(printf '%s' "$body" | jq -c '. + {wiring_check: true}')"
  echo "POST $api_base/v1/releases (wiring check)"
  echo "Request body: $wbody"
  receipt="$(state_dir)/receipt.json"
  code="$(curl -sS -o "$receipt" -w '%{http_code}' \
    -X POST "$api_base/v1/releases" \
    -H "Authorization: Bearer ${VERGING_API_KEY:?VERGING_API_KEY is not set}" \
    -H "Content-Type: application/json" \
    -d "$wbody")" || code="000"
  if [ "$code" != "202" ]; then
    echo "::error::POST /v1/releases (wiring check) returned HTTP $code (expected 202)"
    print_error_body "$receipt"
    {
      echo "## Verging Memory CI: wiring check not accepted"
      echo
      echo "POST /v1/releases with wiring_check: true returned HTTP $code."
      echo
      echo '```'
      cat "$receipt" 2>/dev/null || true
      echo '```'
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    return 1
  fi
  release_id="$(jq -r '.release_id // empty' "$receipt")"
  if [ -z "$release_id" ]; then
    echo "::error::the wiring check's receipt carries no release_id"
    cat "$receipt"
    return 1
  fi
  echo "Receipt (HTTP 202, wiring check):"
  jq -r '
    "  release_id:     \(.release_id)",
    "  received_at:    \(.received_at // "(not given)")",
    "  status:         \(.status // "(not given)")",
    "  message:        \(.message // "(not given)")"
  ' "$receipt"
  release_date="$(jq -r '.received_at // empty' "$receipt" | cut -c1-10)"
  [ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"
  state_set release_id "$release_id"
  state_set release_date "$release_date"
  state_set wiring_why "$why"
  {
    echo "## Verging Memory CI"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| wiring check | \`$release_id\` |"
    echo "| vendor_version | \`$vendor_version\` |"
    echo "| environments | \`$(printf '%s' "$environments_json" | jq -r 'join(", ")')\` |"
    echo "| received_at | $(jq -r '.received_at // "(not given)"' "$receipt") |"
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fetch_and_write_wiring "$release_id" "$release_date"
}

# The wiring_check input: the free wiring check instead of a release.
if [ "$(state_get wiring_check)" = "true" ]; then
  echo "wiring_check is true: this run performs the free wiring check instead of a release and commits its page. Nothing is tested and nothing is billed."
  submit_wiring_check "$body" "input" || exit 1
  exit 0
fi

echo "POST $api_base/v1/releases"
echo "Request body: $body"

receipt="$(state_dir)/receipt.json"
code="$(curl -sS -o "$receipt" -w '%{http_code}' \
  -X POST "$api_base/v1/releases" \
  -H "Authorization: Bearer ${VERGING_API_KEY:?VERGING_API_KEY is not set}" \
  -H "Content-Type: application/json" \
  -d "$body")" || code="000"

if [ "$code" != "202" ]; then
  # The one refusal this action acts on by name: HTTP 409 whose body carries
  # code "not_set_up" means Verging Labs has not activated the test suites on
  # the named agent setups yet. It is read from the body's `code` field, never
  # from the English text. The free wiring check is performed instead, its
  # page is committed, and the job passes. Every other refusal, 409 or not,
  # fails the job exactly as before.
  refusal_code=""
  if [ "$code" = "409" ] && jq -e . "$receipt" >/dev/null 2>&1; then
    refusal_code="$(jq -r '.code // empty' "$receipt")"
  fi
  if [ "$refusal_code" = "not_set_up" ]; then
    echo "POST /v1/releases returned HTTP 409 with code not_set_up:"
    print_error_body "$receipt"
    echo "Verging Labs has not activated the test suites on your agent setups yet, so this run performs the free wiring check instead of a release. Nothing is used or billed for the refused release."
    submit_wiring_check "$body" "not_set_up" || exit 1
    exit 0
  fi
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
  "  scope:          \(if .scope == null then "null (all suites chosen and set up on every named setup)" else (.scope | tojson) end)",
  "  scope_summary:  \(.scope_summary // "(not given)")",
  "  status_url:     \(.status_url // "(not given)")",
  "  message:        \(.message // "(not given)")"
' "$receipt"
echo "If this job stops before the report is committed, the release stays on record as pending and the next job commits the report; to fetch it by hand, re-run with fetch_only_release_id=$release_id (nothing is submitted again)."

release_date="$(jq -r '.received_at // empty' "$receipt" | cut -c1-10)"
[ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"
state_set release_id "$release_id"
state_set release_date "$release_date"

# The pending record, written the moment the release is accepted: it is
# committed with the folder whenever this job stops before the report is in,
# and the reconcile pass of a later job collects the report from it.
submitted_at="$(jq -r '.received_at // empty' "$receipt")"
[ -n "$submitted_at" ] || submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pending_set "$folder" "$release_id" "$(jq -cn \
  --arg vendor_version "$vendor_version" \
  --argjson environments "$environments_json" \
  --arg submitted_at "$submitted_at" \
  --arg status "$(jq -r '.status // "queued"' "$receipt")" \
  '{vendor_version: $vendor_version, environments: $environments, submitted_at: $submitted_at, status: $status}')"
echo "Release $release_id is on record as pending in $folder/releases/pending.json until its report reaches the folder."

{
  echo "## Verging Memory CI"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| vendor_version | \`$vendor_version\` |"
  echo "| environments | \`$(printf '%s' "$environments_json" | jq -r 'join(", ")')\` |"
  echo "| release_id | \`$release_id\` |"
  echo "| received_at | $(jq -r '.received_at // "(not given)"' "$receipt") |"
  echo "| scope | \`$(jq -c '.scope' "$receipt")\` |"
  echo "| scope_summary | $(jq -r '.scope_summary // "(not given)"' "$receipt") |"
  echo
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

wait_for_report "$release_id"
fetch_and_write "$release_id" "$release_date"
