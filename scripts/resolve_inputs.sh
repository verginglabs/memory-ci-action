#!/usr/bin/env bash
# Validate the inputs and store the resolved, non-secret values for the
# later steps. Fails in seconds on anything the API would refuse anyway.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ -z "${VERGING_API_KEY:-}" ]; then
  echo "::error::the api_key input is empty; pass your Verging Memory CI API key from a repository secret"
  exit 1
fi
# The mode. "release", the default, submits a release and commits its
# report. "sync" (D4-A, 2026-08-23) submits nothing: the whole job is the
# finals sync that release-mode jobs run at their start, so the final report
# can be collected on demand or on a schedule between releases. A sync job
# needs no environment and no version: the folder itself says what is
# awaited.
mode="${VERGING_MODE:-release}"
[ -n "$mode" ] || mode="release"
case "$mode" in
  release|sync) ;;
  *)
    echo "::error::mode '$mode' is not one this action provides. Fix: use \"release\" to submit a release, or \"sync\" to commit the final reports that are now out."
    exit 1
    ;;
esac
state_set mode "$mode"

if [ "$mode" = "sync" ]; then
  if [ -n "${VERGING_FETCH_ONLY_RELEASE_ID:-}" ]; then
    echo "::error::fetch_only_release_id does not combine with mode \"sync\". Fix: use mode \"release\" with fetch_only_release_id to fetch one release's report, or mode \"sync\" alone to collect every final report that is out."
    exit 1
  fi
  state_set api_base "${VERGING_API_BASE:-https://ci.verginglabs.com}"
  state_set folder "${VERGING_FOLDER:-Verging Memory CI}"
  state_set fetch_only ""
  echo "mode is sync: nothing is submitted; the releases already in the folder whose final report is out are fetched and committed."
  exit 0
fi

if [ -z "${VERGING_ENVIRONMENT:-}" ]; then
  echo "::error::the environment input is empty; name the environment to test in, as you named it at onboarding"
  exit 1
fi
# The environment (agent setup) name follows the API's display-name rule, so
# "Production MCP" is a name, not an error. It also becomes a directory in the
# report folder, so the slug it produces is checked here rather than after a
# report has already been built around it.
if ! safe_title_ok "$VERGING_ENVIRONMENT"; then
  echo "::error::environment '$VERGING_ENVIRONMENT' is not valid. Fix: use letters, digits, spaces, dots, underscores, plus signs, and hyphens only; single spaces between words, none at the start or the end; up to 64 characters; it must not start with a hyphen."
  exit 1
fi
if ! safe_path_segment_ok "$(agent_setup_slug "$VERGING_ENVIRONMENT")"; then
  echo "::error::environment '$VERGING_ENVIRONMENT' cannot name the folder its evidence files go in. Fix: give the agent setup a name that is not '.' or '..'."
  exit 1
fi

state_set api_base "${VERGING_API_BASE:-https://ci.verginglabs.com}"
state_set folder "${VERGING_FOLDER:-Verging Memory CI}"
state_set endpoint "${VERGING_ENDPOINT:-cfg:standing}"
state_set environment "$VERGING_ENVIRONMENT"
state_set fetch_only "${VERGING_FETCH_ONLY_RELEASE_ID:-}"

timeout="${VERGING_POLL_TIMEOUT_MINUTES:-45}"
if ! printf '%s' "$timeout" | grep -Eq '^[0-9]+$'; then
  echo "::error::poll_timeout_minutes '$timeout' is not a whole number of minutes"
  exit 1
fi
state_set poll_timeout_minutes "$timeout"

# product_name: the API's display-name rule, the same one the environment
# name follows, checked here so a bad value fails before anything is
# submitted, with the same fix wording the API answers with. It titles the
# report and never becomes a path, so spaces are fine in it.
product_name="${VERGING_PRODUCT_NAME:-}"
if [ -n "$product_name" ]; then
  if ! safe_title_ok "$product_name"; then
    echo "::error::product_name '$product_name' is not valid. Fix: use letters, digits, spaces, dots, underscores, plus signs, and hyphens only; single spaces between words, none at the start or the end; up to 64 characters; it must not start with a hyphen."
    exit 1
  fi
fi
state_set product_name "$product_name"

# suites: comma separated values to a JSON array. An empty value means Full
# Coverage: the suites field is omitted from the request.
suites_csv="${VERGING_SUITES:-}"
suites_json=""
if [ -n "$suites_csv" ]; then
  suites_json="$(printf '%s' "$suites_csv" \
    | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  if [ "$suites_json" = "[]" ]; then
    suites_json=""
  fi
fi
state_set suites_json "$suites_json"

# vendor_version: the input, else the VERSION file at the repository root,
# else the short commit SHA. In fetch-only mode it comes from the fetched
# report instead.
if [ -n "$(state_get fetch_only)" ]; then
  echo "fetch_only_release_id is set; vendor_version comes from the fetched report"
  state_set vendor_version ""
  exit 0
fi

v="${VERGING_VENDOR_VERSION:-}"
if [ -n "$v" ]; then
  echo "vendor_version from the vendor_version input: $v"
elif [ -f VERSION ]; then
  v="$(tr -d '[:space:]' < VERSION)"
  echo "vendor_version from the VERSION file: $v"
fi
if [ -z "$v" ]; then
  v="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "$v" ]; then
    v="$(printf '%s' "${GITHUB_SHA:-}" | cut -c1-7)"
  fi
  if [ -n "$v" ]; then
    echo "vendor_version from the commit SHA: $v"
  fi
fi
if [ -z "$v" ]; then
  echo "::error::no vendor_version: pass the vendor_version input, keep a VERSION file at the repository root, or run with a checked-out commit"
  exit 1
fi
# vendor_version keeps the API's SLUG rule (no spaces): it names the
# delivered evidence files, so it is a path segment.
if ! safe_name_ok "$v" || ! safe_path_segment_ok "$v"; then
  echo "::error::vendor_version '$v' is not valid. Fix: use letters, digits, dots, underscores, plus signs, and hyphens only; up to 64 characters; it must not start with a hyphen."
  exit 1
fi
state_set vendor_version "$v"
