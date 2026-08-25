#!/usr/bin/env bash
# Validate the inputs and store the resolved, non-secret values for the
# later steps. Fails in seconds on anything the API would refuse anyway.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ -z "${VERGING_API_KEY:-}" ]; then
  echo "::error::the api_key input is empty; pass your Verging Memory CI API key from a repository secret"
  exit 1
fi

# mode: `release` (default) submits a release and collects its report; `sync`
# submits nothing and lets the reconcile pass collect any final reports now
# ready for releases already in the report folder. Sync needs no environment
# and no version, so it validates only what the reconcile pass reads and exits.
mode="${VERGING_MODE:-release}"
if [ "$mode" != "release" ] && [ "$mode" != "sync" ]; then
  echo "::error::mode '$mode' is not valid. Fix: use 'release' (the default: submit a release and collect its report) or 'sync' (submit nothing and collect final reports already in the report folder)."
  exit 1
fi
state_set mode "$mode"
if [ "$mode" = "sync" ]; then
  if [ -n "${VERGING_FETCH_ONLY_RELEASE_ID:-}" ]; then
    echo "::error::mode: sync collects every ready final report in the folder and cannot be combined with fetch_only_release_id (which fetches one specific release). Fix: use one or the other."
    exit 1
  fi
  if [ "${VERGING_WIRING_CHECK:-false}" = "true" ]; then
    echo "::error::mode: sync submits nothing and cannot be combined with wiring_check (which submits a wiring check). Fix: use one or the other."
    exit 1
  fi
  # Only the reconcile pass runs after this; set exactly what it reads.
  state_set api_base "${VERGING_API_BASE:-https://ci.verginglabs.com}"
  state_set folder "${VERGING_FOLDER:-Verging Memory CI}"
  echo "mode sync: nothing is submitted; the reconcile pass collects any final reports now ready for releases already in the report folder."
  exit 0
fi
# The agent setup(s) this release runs in, named in the `environments` input:
# one name or several, a list separated by commas and/or newlines. One name is
# a one-item list; several are tested together in one release (parity with the
# API, whose `environments` is an array). Each name follows the API's
# display-name rule, so "Production MCP" is a name, not an error. Each also
# becomes a directory in the report folder, so the slug it produces is checked
# here rather than after a report has been built.
env_list="${VERGING_ENVIRONMENTS:-}"

# validate_setup_name NAME: the display-name rule plus the folder-name rule.
validate_setup_name() {
  local name="$1"
  if ! safe_title_ok "$name"; then
    echo "::error::agent setup '$name' is not valid. Fix: use letters, digits, spaces, dots, underscores, plus signs, and hyphens only; single spaces between words, none at the start or the end; up to 64 characters; it must not start with a hyphen."
    return 1
  fi
  if ! safe_path_segment_ok "$(agent_setup_slug "$name")"; then
    echo "::error::agent setup '$name' cannot name the folder its evidence files go in. Fix: give the agent setup a name that is not '.' or '..'."
    return 1
  fi
}

if [ -z "$env_list" ]; then
  echo "::error::name the agent setup(s) to test in the environments input: one name, or several separated by commas and/or newlines. Name them as you named them at onboarding."
  exit 1
fi
# Split the list on commas and newlines, trim each name, and drop empties, so
# a trailing comma or a blank line is not itself a name. The delimiter is
# never validated as a name; only the names between delimiters are.
environments_json="$(printf '%s' "$env_list" \
  | jq -Rsc 'split("\n") | map(split(",")) | add | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
if [ "$environments_json" = "[]" ]; then
  echo "::error::the environments input has no agent-setup names once the separators are removed; name at least one agent setup, e.g. \"staging-mcp\" or \"staging-mcp,prod-mcp\""
  exit 1
fi
# The API refuses a repeated name; refuse it here too so it fails in seconds.
if [ "$(printf '%s' "$environments_json" | jq 'length')" != "$(printf '%s' "$environments_json" | jq 'unique | length')" ]; then
  echo "::error::the environments input names an agent setup more than once. Fix: name every agent setup once; each named setup is tested once per release."
  exit 1
fi
while IFS= read -r name; do
  validate_setup_name "$name" || exit 1
done < <(printf '%s' "$environments_json" | jq -r '.[]')

state_set api_base "${VERGING_API_BASE:-https://ci.verginglabs.com}"
state_set folder "${VERGING_FOLDER:-Verging Memory CI}"
state_set environments_json "$environments_json"
state_set fetch_only "${VERGING_FETCH_ONLY_RELEASE_ID:-}"

# wiring_check: "true" performs the free wiring check instead of a release.
# Its page is committed exactly like a report; nothing is tested and nothing
# is billed. It cannot be combined with fetch_only_release_id, which submits
# nothing at all. (Without it, a release the API refuses with code
# "not_set_up" is turned into a wiring check on its own; see run_release.sh.)
wiring_check="${VERGING_WIRING_CHECK:-false}"
case "$wiring_check" in
  true|false) ;;
  *)
    echo "::error::wiring_check '$wiring_check' is not valid. Fix: use 'true' (perform the free wiring check instead of a release) or 'false' (the default: submit a release)."
    exit 1
    ;;
esac
if [ "$wiring_check" = "true" ] && [ -n "${VERGING_FETCH_ONLY_RELEASE_ID:-}" ]; then
  echo "::error::wiring_check submits a wiring check, and fetch_only_release_id submits nothing; they cannot be combined. Fix: use one or the other."
  exit 1
fi
state_set wiring_check "$wiring_check"

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

# suites: comma separated values to a JSON array. An empty value means all the
# suites chosen for the account: the suites field is omitted from the request.
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
