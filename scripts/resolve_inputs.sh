#!/usr/bin/env bash
# Validate the inputs and store the resolved, non-secret values for the
# later steps. Fails in seconds on anything the API would refuse anyway.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ -z "${VERGING_API_KEY:-}" ]; then
  echo "::error::the api_key input is empty; pass your Verging Memory CI API key from a repository secret"
  exit 1
fi
if [ -z "${VERGING_ENVIRONMENT:-}" ]; then
  echo "::error::the environment input is empty; name the environment to test in, as you named it at onboarding"
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

# product_name: same character rule as vendor_version, checked here so a bad
# value fails before anything is submitted, with the same fix wording the
# API answers with.
product_name="${VERGING_PRODUCT_NAME:-}"
if [ -n "$product_name" ]; then
  if ! printf '%s' "$product_name" | grep -Eq '^[A-Za-z0-9._+][A-Za-z0-9._+-]{0,63}$'; then
    echo "::error::product_name '$product_name' is not valid. Fix: use letters, digits, dots, underscores, plus signs, and hyphens only; up to 64 characters; it must not start with a hyphen."
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
if ! printf '%s' "$v" | grep -Eq '^[A-Za-z0-9._+][A-Za-z0-9._+-]{0,63}$'; then
  echo "::error::vendor_version '$v' is not valid. Fix: use letters, digits, dots, underscores, plus signs, and hyphens only; up to 64 characters; it must not start with a hyphen."
  exit 1
fi
state_set vendor_version "$v"
