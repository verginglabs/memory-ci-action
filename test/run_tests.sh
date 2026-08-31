#!/usr/bin/env bash
# Test harness for the Verging Memory CI action scripts. Plain bash, no
# frameworks. Every case runs the real scripts against a canned-body HTTP
# server (test/mock_api.py), local git repositories, and a gh shim on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="$ROOT/test"
WORK_BASE="$(mktemp -d)"
PASS=0
FAIL=0
FAILED_CASES=()
MOCK_PID=""

say() { printf '%s\n' "$*"; }

# ---------- assertion helpers ----------

note_fail() { CASE_FAILED=1; say "    FAILED: $*"; }

check_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then say "    ok: $1"; else note_fail "$1 (expected '$2', got '$3')"; fi
}

check_exit() { # desc expected_code actual_code
  check_eq "$1" "$2" "$3"
}

check_file() { # desc path
  if [ -f "$2" ]; then say "    ok: $1"; else note_fail "$1 (missing file $2)"; fi
}

check_no_path() { # desc path
  if [ -e "$2" ]; then note_fail "$1 (unexpected path $2)"; else say "    ok: $1"; fi
}

check_grep() { # desc fixed-string file
  if grep -qF -- "$2" "$3" 2>/dev/null; then say "    ok: $1"; else note_fail "$1 (no '$2' in $3)"; fi
}

check_no_grep() { # desc fixed-string file
  if grep -qF -- "$2" "$3" 2>/dev/null; then note_fail "$1 (found '$2' in $3)"; else say "    ok: $1"; fi
}

check_dirs_equal() { # desc dir1 dir2
  if diff -r "$2" "$3" >/dev/null 2>&1; then say "    ok: $1"; else note_fail "$1 ($2 and $3 differ)"; fi
}

# ---------- case plumbing ----------

begin_case() {
  CASE_NAME="$1"
  CASE_FAILED=0
  CASE_TMP="$WORK_BASE/case-$(printf '%s' "$1" | tr ' /' '--')"
  mkdir -p "$CASE_TMP"
  : > "$CASE_TMP/run.log"
  say ""
  say "CASE: $1"
}

end_case() {
  stop_mock
  if [ "$CASE_FAILED" = "0" ]; then
    PASS=$((PASS + 1))
    say "  PASS: $CASE_NAME"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$CASE_NAME")
    say "  FAIL: $CASE_NAME"
    say "  --- last lines of the run log ---"
    tail -n 60 "$CASE_TMP/run.log" 2>/dev/null | sed 's/^/  | /'
  fi
}

start_mock() { # $1 scenario json
  MOCK_DIR="$CASE_TMP/mock"
  mkdir -p "$MOCK_DIR"
  printf '%s' "$1" > "$MOCK_DIR/scenario.json"
  : > "$MOCK_DIR/requests.log"
  rm -f "$MOCK_DIR/port"
  MOCK_DIR="$MOCK_DIR" python3 "$TESTDIR/mock_api.py" &
  MOCK_PID=$!
  local i
  for i in $(seq 1 200); do
    [ -f "$MOCK_DIR/port" ] && break
    sleep 0.05
  done
  if [ ! -f "$MOCK_DIR/port" ]; then
    say "    FAILED: mock API did not start"
    CASE_FAILED=1
    MOCK_PORT="0"
    return 1
  fi
  MOCK_PORT="$(cat "$MOCK_DIR/port")"
}

stop_mock() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
    MOCK_PID=""
  fi
}

setup_env() {
  export RUNNER_TEMP="$CASE_TMP/runner"
  mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$CASE_TMP/github_output"
  : > "$GITHUB_OUTPUT"
  export GITHUB_STEP_SUMMARY="$CASE_TMP/github_summary"
  : > "$GITHUB_STEP_SUMMARY"
  export GITHUB_ACTION_PATH="$ROOT"
  export GITHUB_REPOSITORY="acme/widget"
  export GITHUB_EVENT_NAME="push"
  export GITHUB_REF_NAME="main"
  export GITHUB_SHA="1111111111111111111111111111111111111111"
  unset GITHUB_HEAD_REF GITHUB_EVENT_PATH GITHUB_WORKSPACE 2>/dev/null
  export GH_SHIM_LOG="$CASE_TMP/gh.log"
  : > "$GH_SHIM_LOG"
  export POLL_INTERVAL_SECONDS=0
  export VERGING_API_KEY="test-key"
  export VERGING_AGENT_SETUPS="staging-mcp"
  export VERGING_API_BASE="http://127.0.0.1:${MOCK_PORT:-0}"
  # The same value action.yml declares as the input default; the happy path
  # case checks the two stay in step.
  export VERGING_SUITES=""   # the action.yml default: omit -> all chosen suites
  unset VERGING_VENDOR_VERSION VERGING_ENDPOINT VERGING_FOLDER 2>/dev/null
  unset VERGING_PRODUCT_NAME VERGING_FETCH_ONLY_RELEASE_ID VERGING_POLL_TIMEOUT_MINUTES VERGING_MODE VERGING_LEGACY_ENVIRONMENTS 2>/dev/null
  unset VERGING_DEFAULT_BRANCH VERGING_FALLBACK_PULL_REQUEST GH_PR_LIST_OUTPUT GH_COMMENTS_OUTPUT GH_SHIM_FAIL 2>/dev/null
}

make_repos() {
  ORIGIN="$CASE_TMP/origin.git"
  WORKSPACE="$CASE_TMP/workspace"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git -c init.defaultBranch=main init -q "$WORKSPACE"
  (
    cd "$WORKSPACE"
    git config user.name "Customer"
    git config user.email "customer@example.invalid"
    printf '2.31.0\n' > VERSION
    git add VERSION
    git commit -qm "initial commit"
    git remote add origin "$ORIGIN"
    git push -q origin HEAD:main
  )
  export GITHUB_WORKSPACE="$WORKSPACE"
}

run_step() { # $1 script name; sets STEP_EXIT
  ( cd "$WORKSPACE" && "$ROOT/scripts/$1" ) >> "$CASE_TMP/run.log" 2>&1
  STEP_EXIT=$?
}

# ---------- fixtures ----------

make_report_md() { # $1 tested line, $2 verdict, $3 stage words
  printf '# Regression Report for %s\n\n| **Tested** | %s |\n|---|---|\n| **Release verdict** | %s |\n| **Stage** | %s |\n\n## Results at a glance\n\n**Accuracy:** as measured.\n' \
    "$1" "$1" "$2" "$3"
}

happy_scenario() { # $1 release id
  local md
  md="$(make_report_md "Larkspur 2.31.0" "Ready" "Preliminary report (the final report follows)")"
  jq -n --arg md "$md" --arg rid "$1" '{
    receipt: {
      release_id: $rid,
      received_at: "2026-08-15T08:25:59.868Z",
      scope: {suites: ["core-recall","preference-adherence","truth-maintenance"]},
      scope_summary: "This release covers the Core Recall, Preference Adherence and Truth Maintenance test suites.",
      status_url: ("/v1/releases/" + $rid),
      message: "release received and queued; your preliminary report is delivered as soon as this release completes"
    },
    statuses: [
      {release_id: $rid, status: "running", updated_at: "2026-08-15T08:26:09Z"},
      {release_id: $rid, status: "report_ready", updated_at: "2026-08-15T08:31:00Z", corrections_due_by: "2026-08-18"}
    ],
    report: {
      release_id: $rid,
      status: "report_ready",
      vendor_version: "2.31.0",
      scope: {suites: ["core-recall","preference-adherence","truth-maintenance"]},
      corrections_due_by: "2026-08-18",
      report_markdown: $md,
      diff: {format: "release-diff/v1", verdict: "pass", cost_verdict: "pass",
             release_verdict: "ready", stage: "preliminary"},
      evidence: [
        {name: "evidence/production-mcp/cr1c07-2.31.0.md", content: "what was asked, what each release answered"},
        {name: "evidence/production-mcp/tm1c02-2.31.0.md", content: "second evidence file"},
        {name: "evidence/cr1u11-2.31.0.md", content: "a flat name, the shape a single-setup release still uses"}
      ]
    }
  }'
}

# ---------- the cases ----------

FOLDER="Verging Memory CI"

case_happy_path() {
  begin_case "submit, poll, fetch: the folder layout, the commit, the check"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos

  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  run_step surfaces.sh;        check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh;     check_exit "set_outputs exits 0" 0 "$STEP_EXIT"

  local dir="$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  check_file "REPORT.md written" "$dir/REPORT.md"
  check_file "diff.json written" "$dir/diff.json"
  check_file "release.json written" "$dir/release.json"
  check_file "per-setup evidence file written under its setup directory" "$dir/evidence/production-mcp/cr1c07-2.31.0.md"
  check_file "second per-setup evidence file written" "$dir/evidence/production-mcp/tm1c02-2.31.0.md"
  check_file "flat evidence file written" "$dir/evidence/cr1u11-2.31.0.md"
  check_grep "evidence content is the delivered content" "what was asked, what each release answered" "$dir/evidence/production-mcp/cr1c07-2.31.0.md"
  check_eq "every evidence file the report serves is on disk" "3" \
    "$(find "$dir/evidence" -type f -name '*.md' | wc -l | tr -d ' ')"
  check_grep "the log states what was written against what was served" "Wrote 3 of 3 evidence file(s)" "$CASE_TMP/run.log"
  check_file "index.md written" "$WORKSPACE/$FOLDER/releases/index.md"
  check_grep "index row carries the release" "[$rid](2026-08-15-2.31.0/REPORT.md) | Ready | preliminary" "$WORKSPACE/$FOLDER/releases/index.md"
  check_file "folder README written" "$WORKSPACE/$FOLDER/README.md"
  if cmp -s "$WORKSPACE/$FOLDER/README.md" "$ROOT/scripts/folder-readme.md"; then
    say "    ok: folder README matches the template"
  else
    note_fail "folder README does not match the template"
  fi
  check_dirs_equal "latest/ is a full copy of the release directory" "$dir" "$WORKSPACE/$FOLDER/latest"
  check_eq "release.json holds the four fields" \
    "$rid 2.31.0 2026-08-18" \
    "$(jq -r '"\(.release_id) \(.vendor_version) \(.corrections_due_by)"' "$dir/release.json")"

  check_grep "output release_id" "release_id=$rid" "$GITHUB_OUTPUT"
  check_grep "output verdict" "verdict=Ready" "$GITHUB_OUTPUT"
  check_grep "output report_path" "report_path=$FOLDER/releases/2026-08-15-2.31.0/REPORT.md" "$GITHUB_OUTPUT"

  check_eq "exactly one release submitted" "1" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  local posted
  posted="$(jq -rs '[.[] | select(.method == "POST")][0].body' "$MOCK_DIR/requests.log")"
  check_eq "submitted vendor_version comes from the VERSION file" "2.31.0" "$(printf '%s' "$posted" | jq -r '.vendor_version')"
  check_eq "no endpoint is submitted (the origin is pinned server-side at onboarding)" "null" "$(printf '%s' "$posted" | jq -r '.endpoint')"
  check_eq "no suites submitted by default (all chosen suites)" "null" "$(printf '%s' "$posted" | jq -r '.suites')"
  check_eq "submitted agent_setups (one-item array)" '["staging-mcp"]' "$(printf '%s' "$posted" | jq -c '.agent_setups')"
  check_eq "no product_name submitted when the input is empty" "null" "$(printf '%s' "$posted" | jq -r '.product_name')"
  check_eq "no wiring_check field on a normal release" "null" "$(printf '%s' "$posted" | jq -r '.wiring_check')"
  check_no_grep "a normal release never says wiring check" "wiring check" "$CASE_TMP/run.log"
  check_no_grep "no notice on a normal release" "::notice::" "$CASE_TMP/run.log"
  check_grep "action.yml suites default is empty (all chosen)" 'Omit it (the default) to run all the suites chosen' "$ROOT/action.yml"
  check_no_grep "action.yml declares no endpoint input" 'endpoint:' "$ROOT/action.yml"
  check_grep "the release went on record as pending at the receipt" "is on record as pending in $FOLDER/releases/pending.json" "$CASE_TMP/run.log"
  check_no_path "no pending record once the report is in the folder" "$WORKSPACE/$FOLDER/releases/pending.json"

  check_eq "report commit is on the triggering branch" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "the log says the push path plainly" "Report commit pushed to main." "$CASE_TMP/run.log"
  check_grep "receipt echoed" "Receipt (HTTP 202):" "$CASE_TMP/run.log"
  check_grep "recovery hint printed with the receipt" "fetch_only_release_id=$rid" "$CASE_TMP/run.log"
  check_grep "job summary carries the verdict" "### Release verdict: Ready" "$GITHUB_STEP_SUMMARY"
  check_grep "job summary carries the top of the report" "Regression Report for Larkspur 2.31.0" "$GITHUB_STEP_SUMMARY"
  check_grep "check run posted" "check-runs" "$GH_SHIM_LOG"
  check_grep "check run conclusion is success for Ready" "conclusion=success" "$GH_SHIM_LOG"
  check_no_grep "no pull request comment on a push event" "issues/" "$GH_SHIM_LOG"
  end_case
}

case_name_rules() {
  begin_case "the name rules are the API's name rules, and every slug they produce is a safe folder name"
  MOCK_PORT="0"
  setup_env
  make_repos

  # ---- the rules as functions, against the API's own two regular expressions.
  # SAFE_TITLE_RE covers product_name and the environment (agent setup) name;
  # SAFE_NAME_RE covers vendor_version.
  ( set +u; source "$ROOT/scripts/lib.sh" >/dev/null 2>&1
    long64="$(printf 'a%.0s' $(seq 1 64))"
    long65="$(printf 'a%.0s' $(seq 1 65))"
    fails=0
    accept_title() { safe_title_ok "$1" || { echo "TITLE SHOULD ACCEPT: [$1]"; fails=1; }; }
    refuse_title() { safe_title_ok "$1" && { echo "TITLE SHOULD REFUSE: [$1]"; fails=1; }; }
    accept_name()  { safe_name_ok  "$1" || { echo "NAME SHOULD ACCEPT: [$1]"; fails=1; }; }
    refuse_name()  { safe_name_ok  "$1" && { echo "NAME SHOULD REFUSE: [$1]"; fails=1; }; }

    # The names #472 D6 A widened the API to accept.
    accept_title "Production MCP"
    accept_title "Agent SDK"
    accept_title "Larkspur Memory"
    accept_title "Larkspur.Memory-2+beta_1"
    accept_title "staging-mcp"
    accept_title "a"
    accept_title "$long64"
    # The names the API refuses, which the action must refuse too.
    refuse_title "bad name!"
    refuse_title "-leading-hyphen"
    refuse_title " leading space"
    refuse_title "trailing space "
    refuse_title "double  space"
    refuse_title "$long65"
    refuse_title "with/slash"
    refuse_title ""
    # vendor_version keeps the slug rule: no spaces there.
    accept_name "2.31.0"; accept_name "_beta"; accept_name "$long64"
    refuse_name "Production MCP"; refuse_name "-lead"; refuse_name "$long65"; refuse_name ""

    # Whatever a name may contain, the folder it produces stays one safe segment.
    [ "$(agent_setup_slug "Production MCP")" = "production-mcp" ] || { echo "SLUG WRONG: Production MCP"; fails=1; }
    [ "$(agent_setup_slug "Agent SDK")" = "agent-sdk" ] || { echo "SLUG WRONG: Agent SDK"; fails=1; }
    safe_path_segment_ok "$(agent_setup_slug "Production MCP")" || { echo "SLUG NOT SAFE: production-mcp"; fails=1; }
    for bad in "." ".." "-x" "" "a/b"; do
      safe_path_segment_ok "$bad" && { echo "SEGMENT SHOULD REFUSE: [$bad]"; fails=1; }
    done
    safe_path_segment_ok "a..b" || { echo "SEGMENT SHOULD ACCEPT: a..b"; fails=1; }

    # The evidence contract follows the same segment rule.
    evidence_name_ok "evidence/production-mcp/cr1c07-1.0.0.md" || { echo "EV SHOULD ACCEPT: per-setup"; fails=1; }
    evidence_name_ok "evidence/cr1c07-1.0.0.md" || { echo "EV SHOULD ACCEPT: flat"; fails=1; }
    evidence_name_ok "evidence/a..b/x.md" || { echo "EV SHOULD ACCEPT: dot inside a segment"; fails=1; }
    for bad in "evidence/../x.md" "evidence/./x.md" "evidence//x.md" "evidence/../../etc/x.md" \
               "evidence/a/b/c.md" "/evidence/x.md" "evidence/x.txt" "evidence/-x.md" "evidence/"; do
      evidence_name_ok "$bad" && { echo "EV SHOULD REFUSE: [$bad]"; fails=1; }
    done
    exit "$fails"
  ) > "$CASE_TMP/rules.log" 2>&1
  if [ "$?" = "0" ]; then
    say "    ok: every name rule case agrees with the API's rules"
  else
    note_fail "a name rule disagrees with the API:"
    sed 's/^/      /' "$CASE_TMP/rules.log"
  fi

  # ---- and through the step a customer's run actually executes.
  export VERGING_PRODUCT_NAME="Larkspur Memory"
  export VERGING_AGENT_SETUPS="Production MCP"
  run_step resolve_inputs.sh
  check_exit "a two-word product name and agent setup are accepted" 0 "$STEP_EXIT"
  check_eq "the environment is stored as the customer named it" '["Production MCP"]' \
    "$(cat "$RUNNER_TEMP/verging-memory-ci-state/agent_setups_json")"
  check_eq "the product name is stored as the customer named it" "Larkspur Memory" \
    "$(cat "$RUNNER_TEMP/verging-memory-ci-state/product_name")"

  export VERGING_PRODUCT_NAME="bad name!"
  run_step resolve_inputs.sh
  check_exit "a name the API refuses is refused here first" 1 "$STEP_EXIT"
  check_grep "the error names product_name" "product_name 'bad name!' is not valid" "$CASE_TMP/run.log"
  check_grep "the fix wording is the API's own" "letters, digits, spaces, dots, underscores, plus signs, and hyphens only; single spaces between words, none at the start or the end" "$CASE_TMP/run.log"

  export VERGING_PRODUCT_NAME="Larkspur.Memory-2+beta_1"
  export VERGING_AGENT_SETUPS=".."
  run_step resolve_inputs.sh
  check_exit "an agent setup whose folder would be the parent directory is refused" 1 "$STEP_EXIT"
  check_grep "the refusal says what it is about" "cannot name the folder its evidence files go in" "$CASE_TMP/run.log"

  export VERGING_AGENT_SETUPS="staging-mcp"
  export VERGING_VENDOR_VERSION="not a version"
  run_step resolve_inputs.sh
  check_exit "vendor_version still refuses spaces" 1 "$STEP_EXIT"
  check_grep "vendor_version keeps the slug fix wording" "letters, digits, dots, underscores, plus signs, and hyphens only; up to 64 characters" "$CASE_TMP/run.log"
  unset VERGING_VENDOR_VERSION
  end_case
}

case_held() {
  begin_case "held status keeps polling until the report is ready"
  local rid="run_20260815_186efbad9769"
  local scenario
  scenario="$(happy_scenario "$rid" | jq --arg rid "$rid" '.statuses = [
    {release_id: $rid, status: "held", message: "your environment is being set up on the Verging side; the release starts on its own"},
    {release_id: $rid, status: "held", message: "your environment is being set up on the Verging side; the release starts on its own"},
    {release_id: $rid, status: "running"},
    {release_id: $rid, status: "report_ready", corrections_due_by: "2026-08-18"}
  ]')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 0 through held" 0 "$STEP_EXIT"
  check_grep "the held message is printed" "held: your environment is being set up on the Verging side" "$CASE_TMP/run.log"
  check_eq "polling continued past held to the report" "4" "$(cat "$MOCK_DIR/status-$rid.count")"
  check_file "report written after held cleared" "$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0/REPORT.md"
  end_case
}

case_failed() {
  begin_case "failed status exits 1 with the failure text"
  local rid="run_20260815_186efbad9769"
  local scenario
  scenario="$(happy_scenario "$rid" | jq --arg rid "$rid" 'del(.report) | .statuses = [
    {release_id: $rid, status: "running"},
    {release_id: $rid, status: "failed", failure: "we could not reach your endpoint from the agent environment"}
  ]')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 1 on failed" 1 "$STEP_EXIT"
  check_grep "the failure text is printed" "we could not reach your endpoint from the agent environment" "$CASE_TMP/run.log"
  check_grep "the voided copy is printed" "The release is voided; voided tests are never billed." "$CASE_TMP/run.log"
  check_no_path "no report written on a failed release" "$WORKSPACE/$FOLDER/latest"
  check_no_path "no index written on a failed release" "$WORKSPACE/$FOLDER/releases/index.md"
  check_no_path "no pending record is left for a failed release" "$WORKSPACE/$FOLDER/releases/pending.json"
  run_step commit_push.sh
  check_exit "commit_push exits 0 with nothing to commit" 0 "$STEP_EXIT"
  check_eq "nothing was committed" "initial commit" "$(git -C "$ORIGIN" log -1 --format=%s main)"
  end_case
}

case_fetch_only() {
  begin_case "fetch-only mode commits an existing report and submits nothing"
  local rid="run_20260810_ffeeddccbbaa"
  local md scenario
  md="$(make_report_md "Larkspur 2.30.9" "Ready" "Final report")"
  scenario="$(jq -n --arg md "$md" --arg rid "$rid" '{
    status_by_id: {($rid): [
      {release_id: $rid, status: "corrected", vendor_version: "2.30.9",
       received_at: "2026-08-10T09:00:00.000Z", corrections_due_by: "2026-08-11"}
    ]},
    report_by_id: {($rid): {
      release_id: $rid, status: "corrected", vendor_version: "2.30.9",
      scope: {suites: ["core-recall"]}, corrections_due_by: "2026-08-11",
      report_markdown: $md,
      diff: {format: "release-diff/v1", verdict: "pass", cost_verdict: "pass",
             release_verdict: "ready", stage: "final", corrections: []},
      evidence: []
    }}
  }')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  make_repos
  export VERGING_FETCH_ONLY_RELEASE_ID="$rid"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh

  check_eq "nothing was submitted" "0" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  check_grep "the log says nothing is submitted" "Nothing is submitted this run." "$CASE_TMP/run.log"
  local dir="$WORKSPACE/$FOLDER/releases/2026-08-10-2.30.9"
  check_file "REPORT.md written" "$dir/REPORT.md"
  check_file "release.json written" "$dir/release.json"
  check_no_path "no evidence directory when every test passed" "$dir/evidence"
  check_dirs_equal "latest/ refreshed" "$dir" "$WORKSPACE/$FOLDER/latest"
  check_eq "committed exactly like a normal run" \
    "Verging Memory CI: report for 2.30.9 ($rid): Ready [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "output release_id" "release_id=$rid" "$GITHUB_OUTPUT"
  end_case
}

# ---------- the wiring check ----------

WIRING_NOTICE="::notice::Verging Labs has not activated the test suites on your agent setups yet, so this run performed the free wiring check instead of a release and committed its page. Verging Labs tells you when your suites are set up; pushes after that run real releases."

make_wiring_md() { # $1 product; the shape the API serves (no verdict row, its own stage)
  printf '# Wiring check for %s\n\nEverything on this page proves your integration reaches us and reports come back.\nThis is a wiring check, not a regression report: no test suite ran, nothing is scored, and it is free.\n\n| **Wiring check** | %s |\n|---|---|\n| **Date** | 2026-08-25 |\n| **Stage** | Wiring check |\n\n## What this page proves\n\n- **Your API key authenticated.**\n' "$1" "$1"
}

wiring_scenario() { # $1 wiring id: the wiring receipt and page; the plain-release receipt is the caller's
  local md
  md="$(make_wiring_md "Larkspur")"
  jq -n --arg md "$md" --arg wid "$1" '{
    wiring_receipt: {
      release_id: $wid,
      received_at: "2026-08-25T09:00:00.000Z",
      wiring_check: true,
      status: "delivered",
      status_url: ("/v1/releases/" + $wid),
      report_url: ("/v1/releases/" + $wid + "/report"),
      message: "this is a wiring check, and it is free: it proves your integration reaches us and reports come back. No test suite ran and nothing is billed. Your wiring report is ready now; fetch it from the report URL on this receipt."
    },
    report_by_id: {($wid): {
      release_id: $wid, status: "delivered", vendor_version: "2.31.0",
      scope: {suites: ["core-recall","preference-adherence","truth-maintenance"]},
      corrections_due_by: null,
      report_markdown: $md,
      diff: {format: "wiring-check/v1", stage: "wiring", wiring_check: true, release_id: $wid,
             verified: {key_authenticated: true, suites: ["core-recall"], report_route: ("/v1/releases/" + $wid + "/report")},
             billing: {billable: false, reason: "wiring check: free, never billed"}},
      evidence: []
    }}
  }'
}

not_set_up_receipt='{
  "error": "Core Recall on staging-mcp is not set up yet on your account",
  "fix": "Verging Labs runs activations first: contact your Verging Labs contact to set it up, or run only the suites already set up on your agent setups (GET /v1/environments)",
  "code": "not_set_up"
}'

check_wiring_page_committed() { # $1 wiring id: the page landed like a report, the job's outputs say so
  local dir="$WORKSPACE/$FOLDER/releases/2026-08-25-2.31.0-wiring-check"
  check_file "the wiring page is written like a report (REPORT.md)" "$dir/REPORT.md"
  check_file "diff.json written" "$dir/diff.json"
  check_file "release.json written" "$dir/release.json"
  check_eq "diff.json carries the wiring format" "wiring-check/v1" "$(jq -r '.format' "$dir/diff.json")"
  check_eq "release.json names the wiring check's id" "$1" "$(jq -r '.release_id' "$dir/release.json")"
  check_no_path "no evidence directory (a wiring check has none)" "$dir/evidence"
  check_no_path "latest/ is left for regression reports" "$WORKSPACE/$FOLDER/latest"
  check_file "folder README written" "$WORKSPACE/$FOLDER/README.md"
  check_grep "index row says Wiring check in place of a verdict" "[$1](2026-08-25-2.31.0-wiring-check/REPORT.md) | Wiring check | wiring |" "$WORKSPACE/$FOLDER/releases/index.md"
  check_eq "the commit is named for what it is" \
    "Verging Memory CI: wiring check for 2.31.0 ($1) [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "output verdict is Wiring check" "verdict=Wiring check" "$GITHUB_OUTPUT"
  check_grep "output release_id is the wiring check's id" "release_id=$1" "$GITHUB_OUTPUT"
  check_grep "output report_path is the committed page" "report_path=$FOLDER/releases/2026-08-25-2.31.0-wiring-check/REPORT.md" "$GITHUB_OUTPUT"
  check_no_path "nothing was polled: a wiring check is served on delivery" "$MOCK_DIR/status-$1.count"
  check_grep "job summary says what this run did" "### Wiring check" "$GITHUB_STEP_SUMMARY"
  check_grep "check run title is not a verdict" "output\[title\]=Wiring\ check\,\ not\ a\ release" "$GH_SHIM_LOG"
  check_grep "check run conclusion is neutral (not a verdict)" "conclusion=neutral" "$GH_SHIM_LOG"
  check_eq "no check run concludes failure" "0" "$(grep -c 'conclusion=failure' "$GH_SHIM_LOG")"
}

case_wiring_check_input() {
  begin_case "wiring_check: true performs the wiring check instead of a release and commits its page"
  local wid="run_20260825_0a1b2c3d4e5f"
  # A plain release POST is refused by the mock, so a run that submitted one
  # instead of the wiring check fails loudly.
  start_mock "$(wiring_scenario "$wid" | jq '.receipt_code = 400 | .receipt = {error: "the test expected a wiring check, not a release", fix: "-"}')" || { end_case; return; }
  setup_env
  make_repos
  export VERGING_WIRING_CHECK="true"
  unset VERGING_AGENT_SETUPS

  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  run_step surfaces.sh;        check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh;     check_exit "set_outputs exits 0: the job is green" 0 "$STEP_EXIT"

  check_eq "exactly one request was submitted" "1" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  local posted; posted="$(posted_body)"
  check_eq "it is a wiring check" "true" "$(printf '%s' "$posted" | jq -r '.wiring_check')"
  check_eq "onboarding wiring check leaves setup scope to account defaults" "false" "$(printf '%s' "$posted" | jq 'has("agent_setups")')"
  check_eq "and the same vendor_version" "2.31.0" "$(printf '%s' "$posted" | jq -r '.vendor_version')"
  check_grep "the log says what this run does" "wiring_check is true: this run performs the free wiring check instead of a release" "$CASE_TMP/run.log"
  check_grep "the closing notice names the input" "::notice::wiring_check is true, so this run performed the free wiring check instead of a release and committed its page." "$CASE_TMP/run.log"
  check_no_grep "no error anywhere in the run" "::error::" "$CASE_TMP/run.log"
  check_wiring_page_committed "$wid"
  check_grep "action.yml declares the wiring_check input" "wiring_check:" "$ROOT/action.yml"

  # The input's own rules.
  export VERGING_WIRING_CHECK="maybe"
  run_step resolve_inputs.sh;  check_exit "a value other than true/false is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names the input" "wiring_check 'maybe' is not valid" "$CASE_TMP/run.log"
  export VERGING_WIRING_CHECK="true"
  export VERGING_FETCH_ONLY_RELEASE_ID="run_20260810_ffeeddccbbaa"
  run_step resolve_inputs.sh;  check_exit "wiring_check + fetch_only_release_id is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names the conflict" "fetch_only_release_id submits nothing; they cannot be combined" "$CASE_TMP/run.log"
  unset VERGING_FETCH_ONLY_RELEASE_ID
  export VERGING_MODE="sync"
  run_step resolve_inputs.sh;  check_exit "wiring_check + mode sync is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names sync" "cannot be combined with wiring_check" "$CASE_TMP/run.log"
  unset VERGING_MODE VERGING_WIRING_CHECK
  end_case
}

case_not_set_up_fallback() {
  begin_case "a 409 with code not_set_up turns the release into a wiring check: green job, page committed, notice emitted"
  local wid="run_20260825_0a1b2c3d4e5f"
  start_mock "$(wiring_scenario "$wid" | jq --argjson r "$not_set_up_receipt" '.receipt_code = 409 | .receipt = $r')" || { end_case; return; }
  setup_env
  make_repos

  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0 on the not_set_up 409" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  # The surfaces on a pull request: the one comment says the same line.
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$CASE_TMP/event.json"
  jq -n '{pull_request: {number: 12, head: {sha: "abc123def4567890abc123def4567890abc123de"}}}' > "$GITHUB_EVENT_PATH"
  run_step surfaces.sh;        check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh;     check_exit "set_outputs exits 0: the job is green" 0 "$STEP_EXIT"

  check_eq "two requests: the release, then the wiring check" "2" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  local first second
  first="$(jq -rs '[.[] | select(.method == "POST")][0].body' "$MOCK_DIR/requests.log")"
  second="$(jq -rs '[.[] | select(.method == "POST")][1].body' "$MOCK_DIR/requests.log")"
  check_eq "the first request is the release (no wiring_check field)" "null" "$(printf '%s' "$first" | jq -r '.wiring_check')"
  check_eq "the second request is the wiring check" "true" "$(printf '%s' "$second" | jq -r '.wiring_check')"
  check_eq "the wiring check carries the release's own fields" "$(printf '%s' "$first" | jq -c '.')" "$(printf '%s' "$second" | jq -c 'del(.wiring_check)')"
  check_grep "the log states the refusal by its code" "POST /v1/releases returned HTTP 409 with code not_set_up" "$CASE_TMP/run.log"
  check_grep "the refusal's own text is shown" "Core Recall on staging-mcp is not set up yet" "$CASE_TMP/run.log"
  check_grep "the exact notice is emitted" "$WIRING_NOTICE" "$CASE_TMP/run.log"
  check_no_grep "no error anywhere in the run" "::error::" "$CASE_TMP/run.log"
  check_no_grep "the job summary never says the release was not accepted" "release not accepted" "$GITHUB_STEP_SUMMARY"
  check_wiring_page_committed "$wid"
  check_grep "the check run says the same in one line" "output\[summary\]=Verging\ Labs\ has\ not\ activated\ the\ test\ suites\ on\ your\ agent\ setups\ yet\,\ so\ this\ run\ performed\ the\ free\ wiring\ check\ instead\ of\ a\ release" "$GH_SHIM_LOG"
  check_grep "the pull request comment is the one-line form" "**Verging Memory CI: wiring check, not a release.** Verging Labs has not activated the test suites on your agent setups yet, so this run performed the free wiring check instead of a release and committed its page" "$GH_SHIM_LOG"
  check_grep "the comment links the committed page" "/acme/widget/blob/main/Verging%20Memory%20CI/releases/2026-08-25-2.31.0-wiring-check/REPORT.md" "$GH_SHIM_LOG"
  check_no_grep "the comment carries no verdict" "[Read the report]" "$GH_SHIM_LOG"
  end_case
}

case_other_409_fails() {
  begin_case "any other refusal fails the job exactly as before: a 409 without the code, a 409 with another code, another status with the code"
  local wid="run_20260825_0a1b2c3d4e5f"
  # 1. A 409 with no code at all.
  start_mock "$(wiring_scenario "$wid" | jq '.receipt_code = 409 | .receipt = {error: "a wiring check needs at least one agent setup on your account, and there is none yet", fix: "contact your Verging Labs onboarding contact to add one"}')" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh;     check_exit "a 409 without code not_set_up fails the job" 1 "$STEP_EXIT"
  check_eq "nothing else was submitted" "1" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  check_grep "the error is the same as before" "::error::POST /v1/releases returned HTTP 409 (expected 202)" "$CASE_TMP/run.log"
  check_grep "the refusal's text is shown" "a wiring check needs at least one agent setup" "$CASE_TMP/run.log"
  check_grep "the job summary says the release was not accepted" "release not accepted" "$GITHUB_STEP_SUMMARY"
  check_no_path "no report folder written" "$WORKSPACE/$FOLDER"
  check_no_grep "no notice" "::notice::" "$CASE_TMP/run.log"

  # 2. A 409 with a different code: the English is never matched, the code is.
  printf '%s' "$(wiring_scenario "$wid" | jq --argjson r "$not_set_up_receipt" '.receipt_code = 409 | .receipt = ($r | .code = "something_else")')" > "$MOCK_DIR/scenario.json"
  : > "$MOCK_DIR/requests.log"
  run_step run_release.sh;     check_exit "a 409 with another code fails even though the text reads not set up" 1 "$STEP_EXIT"
  check_eq "nothing else was submitted" "1" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"

  # 3. The code on a status other than 409 is not the door-check.
  printf '%s' "$(wiring_scenario "$wid" | jq --argjson r "$not_set_up_receipt" '.receipt_code = 402 | .receipt = $r')" > "$MOCK_DIR/scenario.json"
  : > "$MOCK_DIR/requests.log"
  run_step run_release.sh;     check_exit "a 402 carrying the code still fails" 1 "$STEP_EXIT"
  check_eq "nothing else was submitted" "1" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  check_grep "the error names the status" "::error::POST /v1/releases returned HTTP 402 (expected 202)" "$CASE_TMP/run.log"

  # 4. The wiring check itself refused after a not_set_up 409: a real failure.
  printf '%s' "$(wiring_scenario "$wid" | jq --argjson r "$not_set_up_receipt" '.receipt_code = 409 | .receipt = $r | .wiring_receipt_code = 401 | .wiring_receipt = {error: "invalid API key", fix: "pass the key issued at onboarding"}')" > "$MOCK_DIR/scenario.json"
  : > "$MOCK_DIR/requests.log"
  run_step run_release.sh;     check_exit "a refused wiring check fails the job" 1 "$STEP_EXIT"
  check_grep "the error names the wiring check" "::error::POST /v1/releases (wiring check) returned HTTP 401" "$CASE_TMP/run.log"
  check_no_path "no report folder written" "$WORKSPACE/$FOLDER"
  end_case
}

seed_preliminary_release() { # $1 release id; seeds and pushes a preliminary report
  local rid="$1" dir="$WORKSPACE/$FOLDER/releases/2026-08-14-2.30.0"
  mkdir -p "$dir/evidence"
  make_report_md "Larkspur 2.30.0" "Not ready: 2 accuracy failures" "Preliminary report (the final report follows)" > "$dir/REPORT.md"
  jq -n --arg rid "$rid" '{format: "release-diff/v1", verdict: "regressions_found",
    cost_verdict: "pass", release_verdict: "not_ready", stage: "preliminary",
    release_id: $rid}' > "$dir/diff.json"
  jq -n --arg rid "$rid" '{release_id: $rid, vendor_version: "2.30.0",
    scope: {suites: ["core-recall"]}, corrections_due_by: "2026-08-17"}' > "$dir/release.json"
  printf 'old evidence\n' > "$dir/evidence/core-recall-1.md"
  {
    echo "# Releases"
    echo
    echo "One line per release, oldest first. Each release id links to its report."
    echo
    echo "| Date (UTC) | vendor_version | Release id | Release verdict | Stage |"
    echo "|---|---|---|---|---|"
    echo "| 2026-08-14 | 2.30.0 | [$rid](2026-08-14-2.30.0/REPORT.md) | Not ready: 2 accuracy failures | preliminary |"
  } > "$WORKSPACE/$FOLDER/releases/index.md"
  mkdir -p "$WORKSPACE/$FOLDER/latest"
  cp -R "$dir"/. "$WORKSPACE/$FOLDER/latest/"
  cp "$ROOT/scripts/folder-readme.md" "$WORKSPACE/$FOLDER/README.md"
  (
    cd "$WORKSPACE"
    git add "$FOLDER"
    git commit -qm "Verging Memory CI: report for 2.30.0 ($rid): Not ready: 2 accuracy failures"
    git push -q origin HEAD:main
  )
}

case_reconcile() {
  begin_case "the reconcile pass upgrades a preliminary report to final"
  local rid="run_20260814_aaaabbbbcccc"
  local md scenario
  md="$(make_report_md "Larkspur 2.30.0" "Ready" "Final report")"
  scenario="$(jq -n --arg md "$md" --arg rid "$rid" '{
    report_by_id: {($rid): {
      release_id: $rid, status: "corrected", vendor_version: "2.30.0",
      scope: {suites: ["core-recall"]}, corrections_due_by: "2026-08-17",
      report_markdown: $md,
      diff: {format: "release-diff/v1", verdict: "pass", cost_verdict: "pass",
             release_verdict: "ready", stage: "final",
             corrections: [{test: "core-recall-1", from: "fail", to: "pass"}]},
      evidence: []
    }}
  }')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  make_repos
  seed_preliminary_release "$rid"

  run_step resolve_inputs.sh
  run_step reconcile.sh
  check_exit "reconcile exits 0" 0 "$STEP_EXIT"

  local dir="$WORKSPACE/$FOLDER/releases/2026-08-14-2.30.0"
  check_eq "the release directory now holds the final report" "final" "$(jq -r '.stage' "$dir/diff.json")"
  check_grep "REPORT.md rewritten with the final verdict" "| **Release verdict** | Ready |" "$dir/REPORT.md"
  check_no_path "stale evidence removed when the final report has none" "$dir/evidence"
  check_eq "latest/ refreshed because this release is the newest" "final" "$(jq -r '.stage' "$WORKSPACE/$FOLDER/latest/diff.json")"
  check_grep "index row updated to final" "[$rid](2026-08-14-2.30.0/REPORT.md) | Ready | final |" "$WORKSPACE/$FOLDER/releases/index.md"
  check_no_grep "index row no longer says preliminary" "preliminary" "$WORKSPACE/$FOLDER/releases/index.md"
  check_eq "the reconcile commit message" \
    "Verging Memory CI: final report for 2.30.0 ($rid) [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  end_case
}

case_sync_mode() {
  begin_case "mode: sync collects finals with no environment and submits nothing"
  local rid="run_20260814_aaaabbbbcccc"
  local md scenario
  md="$(make_report_md "Larkspur 2.30.0" "Ready" "Final report")"
  scenario="$(jq -n --arg md "$md" --arg rid "$rid" '{
    report_by_id: {($rid): {
      release_id: $rid, status: "corrected", vendor_version: "2.30.0",
      scope: {suites: ["core-recall"]}, corrections_due_by: "2026-08-17",
      report_markdown: $md,
      diff: {format: "release-diff/v1", verdict: "pass", cost_verdict: "pass",
             release_verdict: "ready", stage: "final",
             corrections: [{test: "core-recall-1", from: "fail", to: "pass"}]},
      evidence: []
    }}
  }')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  # Sync needs no environment: unset the one setup_env exports and select sync.
  unset VERGING_AGENT_SETUPS
  export VERGING_MODE="sync"
  make_repos
  seed_preliminary_release "$rid"

  run_step resolve_inputs.sh
  check_exit "resolve_inputs exits 0 in sync mode with no environment" 0 "$STEP_EXIT"
  run_step reconcile.sh
  check_exit "reconcile exits 0" 0 "$STEP_EXIT"

  local dir="$WORKSPACE/$FOLDER/releases/2026-08-14-2.30.0"
  check_eq "the preliminary report was collected as final" "final" "$(jq -r '.stage' "$dir/diff.json")"
  check_grep "the final report replaced the preliminary" "| **Release verdict** | Ready |" "$dir/REPORT.md"

  # The guarded submit step is a safe no-op in sync mode, and nothing is posted.
  run_step run_release.sh
  check_exit "run_release is a no-op in sync mode" 0 "$STEP_EXIT"
  check_no_grep "no release was submitted in sync mode" "release-tests" "$MOCK_DIR/requests.log"

  # sync cannot be combined with fetch_only_release_id.
  export VERGING_FETCH_ONLY_RELEASE_ID="$rid"
  run_step resolve_inputs.sh
  check_exit "sync + fetch_only_release_id is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names the conflict" "cannot be combined with fetch_only_release_id" "$CASE_TMP/run.log"
  end_case
}

case_push_retry() {
  begin_case "a conflicting commit on the branch is absorbed by fetch and rebase"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 0" 0 "$STEP_EXIT"

  # Someone else pushes while we were waiting for the report.
  git clone -q "$ORIGIN" "$CASE_TMP/other"
  (
    cd "$CASE_TMP/other"
    git config user.name "Someone Else"
    git config user.email "else@example.invalid"
    printf 'other work\n' > other.txt
    git add other.txt
    git commit -qm "other work landed while the release ran"
    git push -q origin HEAD:main
  )

  run_step commit_push.sh
  check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  check_grep "the first push attempt failed" "Push attempt 1 to main failed" "$CASE_TMP/run.log"
  check_grep "the push landed after the rebase" "Report commit pushed to main." "$CASE_TMP/run.log"
  check_grep "origin main has the report commit" "Verging Memory CI: report for 2.31.0" <(git -C "$ORIGIN" log --format=%s main)
  check_grep "origin main kept the other commit" "other work landed while the release ran" <(git -C "$ORIGIN" log --format=%s main)
  end_case
}

# reject_pushes_to_main: the origin refuses every push to main from now on,
# as a ruleset or branch protection that does not let the workflow push would.
reject_pushes_to_main() {
  cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
  if [ "$ref" = "refs/heads/main" ]; then
    echo "main is protected" >&2
    exit 1
  fi
done
exit 0
HOOK
  chmod +x "$ORIGIN/hooks/pre-receive"
}

PUSH_REFUSED_ERROR="::error title=Verging Memory CI push refused::The report commit could not be pushed to main after 3 attempts, so it is not in your repository. Nothing else was written: no other branch, no pull request. Fix: allow the workflow's token to push to main."

check_push_refused_cleanly() { # the refusal touched nothing else: no reports branch, no pull request, no default branch
  check_grep "the named error says what was refused and what to allow" "$PUSH_REFUSED_ERROR" "$CASE_TMP/run.log"
  check_grep "the error names the permission" "permissions: contents: write" "$CASE_TMP/run.log"
  check_grep "the job summary carries the refusal" "## Verging Memory CI: push to \`main\` refused" "$GITHUB_STEP_SUMMARY"
  check_eq "no reports branch was written" "" "$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/verging-memory-ci/reports 2>/dev/null || true)"
  check_eq "gh was never asked about a pull request" "0" "$(grep -c '^gh pr' "$GH_SHIM_LOG")"
  check_no_grep "the default branch is never named" "dev" "$GH_SHIM_LOG"
  check_no_grep "the reports branch is never named" "verging-memory-ci/reports" "$CASE_TMP/run.log"
  check_no_grep "no warning stands in for the error" "::warning::could not push" "$CASE_TMP/run.log"
  check_eq "the push path is recorded as refused" "refused" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/push_path")"
}

case_push_refused() {
  begin_case "a refused push fails the job with a named error, writes no other branch and opens no pull request"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  # The repository's default branch is not the branch the job ran on; it
  # must never be touched or named.
  export VERGING_DEFAULT_BRANCH="dev"
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 0" 0 "$STEP_EXIT"
  reject_pushes_to_main

  run_step commit_push.sh
  check_exit "commit_push exits 1: the job fails" 1 "$STEP_EXIT"
  check_grep "the push was retried before failing" "Push attempt 3 to main failed" "$CASE_TMP/run.log"
  check_push_refused_cleanly
  check_grep "the recovery names the release to fetch" "re-run with fetch_only_release_id=$rid to fetch and commit this report without submitting anything" "$CASE_TMP/run.log"
  check_eq "origin main is untouched" "initial commit" "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "action.yml declares the opt-in, off by default" 'fallback_pull_request:' "$ROOT/action.yml"
  check_eq "the opt-in defaults to false in action.yml" "1" "$(grep -A 3 '^  fallback_pull_request:' "$ROOT/action.yml" | grep -c 'default: "false"')"
  check_grep "the README (generated from the setup guide) documents the opt-in" 'fallback_pull_request: "true"' "$ROOT/README.md"
  check_grep "the README says a refused push fails the job" "When the push is refused the job fails with an" "$ROOT/README.md"
  check_no_grep "the README no longer promises a pull request on its own" "opens or updates a pull request" "$ROOT/README.md"

  # A wiring check with the opt-in on: the opt-in is ignored, the job fails
  # the same way, and the page never goes anywhere but the branch it ran on.
  new_job
  set_scenario "$(wiring_scenario "run_20260825_0a1b2c3d4e5f" | jq '.receipt_code = 400 | .receipt = {error: "the test expected a wiring check, not a release", fix: "-"}')"
  export VERGING_WIRING_CHECK="true"
  export VERGING_FALLBACK_PULL_REQUEST="true"
  unset VERGING_AGENT_SETUPS
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  check_grep "the log says the opt-in is ignored during a wiring check" "fallback_pull_request is ignored during a wiring check: the page must land on the branch the job ran on" "$CASE_TMP/run.log"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0: the wiring check itself passed" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 1: the wiring page did not land" 1 "$STEP_EXIT"
  check_grep "the opt-in is refused at push time too" "fallback_pull_request is on, but this job is a wiring check" "$CASE_TMP/run.log"
  check_push_refused_cleanly
  check_grep "the recovery is to re-run the free wiring check" "re-run this workflow: the wiring check is free and is performed again" "$CASE_TMP/run.log"
  check_eq "origin main is still untouched" "initial commit" "$(git -C "$ORIGIN" log -1 --format=%s main)"
  unset VERGING_WIRING_CHECK VERGING_FALLBACK_PULL_REQUEST VERGING_DEFAULT_BRANCH
  end_case
}

case_reconcile_push_refused() {
  begin_case "the reconcile pass fails the job the same way when its push is refused, and leaves the pending record for the next job"
  local rid="run_20260826_5e6f7a8b9c0d"
  start_mock "$(happy_scenario "$rid" | jq --arg rid "$rid" '.statuses = [{release_id: $rid, status: "report_ready", updated_at: "2026-08-15T10:31:00Z", corrections_due_by: "2026-08-18"}]')" || { end_case; return; }
  setup_env
  make_repos
  seed_pending_release "$rid" "2.31.0" "2026-08-15T08:25:59.868Z"
  reject_pushes_to_main
  export VERGING_DEFAULT_BRANCH="dev"
  unset VERGING_AGENT_SETUPS
  export VERGING_MODE="sync"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  check_eq "the opt-in is stored in sync mode too, as false" "false" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/fallback_pull_request")"
  run_step reconcile.sh;       check_exit "reconcile exits 1: the job fails" 1 "$STEP_EXIT"
  check_grep "the report was collected and committed locally first" "Committed the report for 2.31.0 ($rid): Ready" "$CASE_TMP/run.log"
  check_push_refused_cleanly
  check_grep "the recovery is to re-run" "re-run this workflow: the reports it collected are fetched and committed again" "$CASE_TMP/run.log"
  check_eq "origin main still carries the pending record, so the next job collects again" \
    "Verging Memory CI: release 2.31.0 ($rid) is pending; the report follows" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  run_step commit_push.sh;     check_exit "the commit step has nothing of its own to commit" 0 "$STEP_EXIT"
  unset VERGING_MODE VERGING_DEFAULT_BRANCH
  end_case
}

case_fallback_pull_request_opt_in() {
  begin_case "fallback_pull_request: true restores the reports branch and the pull request for a refused push"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  export VERGING_FALLBACK_PULL_REQUEST="true"
  run_step resolve_inputs.sh
  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  check_eq "the opt-in is stored" "true" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/fallback_pull_request")"
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 0" 0 "$STEP_EXIT"
  reject_pushes_to_main

  run_step commit_push.sh
  check_exit "commit_push exits 0 even though the push failed" 0 "$STEP_EXIT"
  check_grep "the log says plainly the direct push failed" "could not push the report commit to main after 3 attempts; fallback_pull_request is on" "$CASE_TMP/run.log"
  check_grep "the log says the pull request path happened" "a pull request into main was opened" "$CASE_TMP/run.log"
  check_no_grep "no error: the job is green on this path" "::error" "$CASE_TMP/run.log"
  check_eq "the reports branch carries the report commit" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s verging-memory-ci/reports)"
  check_grep "gh looked for an existing pull request" "pr list --head verging-memory-ci/reports" "$GH_SHIM_LOG"
  check_grep "gh opened the pull request with the ruled title" "pr create --head verging-memory-ci/reports --base main --title Verging\\ Memory\\ CI\\ reports" "$GH_SHIM_LOG"
  check_eq "the push path is recorded as the fallback" "fallback" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/push_path")"

  # A later run finds the pull request already open and does not open another.
  printf '\n' >> "$WORKSPACE/$FOLDER/releases/index.md"
  export GH_PR_LIST_OUTPUT="7"
  run_step commit_push.sh
  check_exit "the second commit_push exits 0" 0 "$STEP_EXIT"
  check_eq "no second pull request opened" "1" "$(grep -c 'pr create' "$GH_SHIM_LOG")"
  check_grep "the log names the open pull request" "the open pull request #7 into main now carries it" "$CASE_TMP/run.log"
  unset GH_PR_LIST_OUTPUT

  # The input's own rule.
  export VERGING_FALLBACK_PULL_REQUEST="maybe"
  run_step resolve_inputs.sh
  check_exit "a value other than true/false is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names the input" "fallback_pull_request 'maybe' is not valid" "$CASE_TMP/run.log"
  unset VERGING_FALLBACK_PULL_REQUEST
  end_case
}

seed_surfaces_state() { # $1 verdict
  local sd="$RUNNER_TEMP/verging-memory-ci-state"
  mkdir -p "$sd"
  printf '%s' "$1" > "$sd/verdict"
  printf '%s' "run_20260815_186efbad9769" > "$sd/release_id"
  printf '%s' "$FOLDER/releases/2026-08-15-2.31.0/REPORT.md" > "$sd/report_path"
  printf '%s' "feature-x" > "$sd/pushed_ref"
}

case_surfaces() {
  begin_case "check run and comment: neutral is never a failure, one comment per pull request, the comment carries the report's Results at a glance"
  MOCK_PORT="0"
  setup_env
  make_repos
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_HEAD_REF="feature-x"
  export GITHUB_EVENT_PATH="$CASE_TMP/event.json"
  jq -n '{pull_request: {number: 12, head: {sha: "abc123def4567890abc123def4567890abc123de"}}}' > "$GITHUB_EVENT_PATH"

  # First pass: the committed report is NOT on disk. The comment still says
  # what happened and links the report; it just cannot inline the glance.
  seed_surfaces_state "Not ready: 1 accuracy failure"
  run_step surfaces.sh
  check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  check_grep "check posted on the pull request head commit" "head_sha=abc123def4567890abc123def4567890abc123de" "$GH_SHIM_LOG"
  check_grep "Not ready posts conclusion neutral" "conclusion=neutral" "$GH_SHIM_LOG"
  check_grep "comment created on the pull request" "issues/12/comments" "$GH_SHIM_LOG"
  check_grep "comment body starts with the marker" "<!-- verging-memory-ci -->" "$GH_SHIM_LOG"
  check_grep "comment body carries the release id" "run_20260815_186efbad9769" "$GH_SHIM_LOG"
  check_grep "comment links the committed report" "/acme/widget/blob/feature-x/Verging%20Memory%20CI/releases/2026-08-15-2.31.0/REPORT.md" "$GH_SHIM_LOG"
  check_grep "the report link is an anchor that opens in a new tab" \
    '<a href="https://github.com/acme/widget/blob/feature-x/Verging%20Memory%20CI/releases/2026-08-15-2.31.0/REPORT.md" target="_blank">Full report</a>' \
    "$GH_SHIM_LOG"
  check_no_grep "no glance section when the report file is absent" "### Results at a glance" "$GH_SHIM_LOG"

  # A later run updates the same comment in place, now with the committed
  # report on disk: the comment inlines the report's own Results at a glance
  # and links every committed report file, each opening in a new tab.
  local dir="$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  mkdir -p "$dir"
  make_report_md "Larkspur 2.31.0" "Not ready: 1 accuracy failure" "Preliminary report (the final report follows)" > "$dir/REPORT.md"
  printf '{"stage":"preliminary"}\n' > "$dir/diff.json"
  printf '# Releases\n' > "$WORKSPACE/$FOLDER/releases/index.md"
  export GH_COMMENTS_OUTPUT="98765"
  run_step surfaces.sh
  check_exit "surfaces exits 0 on the update pass" 0 "$STEP_EXIT"
  check_grep "the existing comment is updated in place" "issues/comments/98765 -X PATCH" "$GH_SHIM_LOG"
  check_eq "only one comment was ever created" "1" "$(grep -c 'issues/12/comments -X POST' "$GH_SHIM_LOG")"
  check_grep "the comment inlines the glance heading" "### Results at a glance" "$GH_SHIM_LOG"
  check_grep "the comment inlines the glance content" '**Accuracy:** as measured.' "$GH_SHIM_LOG"
  check_grep "diff.json is linked and opens in a new tab" \
    '<a href="https://github.com/acme/widget/blob/feature-x/Verging%20Memory%20CI/releases/2026-08-15-2.31.0/diff.json" target="_blank">diff.json</a>' \
    "$GH_SHIM_LOG"
  check_grep "the releases index is linked and opens in a new tab" \
    '<a href="https://github.com/acme/widget/blob/feature-x/Verging%20Memory%20CI/releases/index.md" target="_blank">All releases</a>' \
    "$GH_SHIM_LOG"
  check_no_grep "the old markdown-only report line is gone" "[Read the report]" "$GH_SHIM_LOG"
  unset GH_COMMENTS_OUTPUT

  # A refusal is also neutral, never a failure.
  seed_surfaces_state "Refused: your agent-facing surface changed"
  run_step surfaces.sh
  check_exit "surfaces exits 0 on a refusal" 0 "$STEP_EXIT"
  check_eq "no check run ever concludes failure" "0" "$(grep -c 'conclusion=failure' "$GH_SHIM_LOG")"
  check_eq "every conclusion is success or neutral" "0" "$(grep 'check-runs' "$GH_SHIM_LOG" | grep -cv -e 'conclusion=success' -e 'conclusion=neutral')"

  # gh going down never fails the job.
  export GH_SHIM_FAIL=1
  run_step surfaces.sh
  check_exit "surfaces exits 0 when gh itself fails" 0 "$STEP_EXIT"
  check_grep "the gh failure is only a warning" "could not post the check run" "$CASE_TMP/run.log"
  unset GH_SHIM_FAIL
  end_case
}

case_evidence_paths() {
  begin_case "evidence files land at the exact paths the report names, and nothing else is written"
  local rid="run_20260820_d55af6c7f6b3"
  local md scenario
  md="$(make_report_md "Larkspur 2.31.0" "Not ready: 1 accuracy failure" "Preliminary report (the final report follows)")"
  # Three names the API emits, and four it never emits. A run that writes
  # the three and refuses the four is the whole point of this case: the
  # earlier writer refused all seven, said it had written seven, and ended
  # green.
  scenario="$(jq -n --arg md "$md" --arg rid "$rid" '{
    receipt: {release_id: $rid, received_at: "2026-08-20T13:40:00.000Z",
              scope: {suites: ["core-recall"]}},
    statuses: [{release_id: $rid, status: "report_ready", corrections_due_by: "2026-08-21"}],
    report: {
      release_id: $rid, status: "report_ready", vendor_version: "2.31.0",
      scope: {suites: ["core-recall"]}, corrections_due_by: "2026-08-21",
      report_markdown: $md,
      diff: {format: "release-diff/v1", release_verdict: "not_ready", stage: "preliminary"},
      evidence: [
        {name: "evidence/production-mcp/cr1c07-2.31.0.md", content: "per setup, first setup"},
        {name: "evidence/agent-sdk/cr1c07-2.31.0.md", content: "per setup, second setup"},
        {name: "evidence/tm1t04-2.31.0.md", content: "flat, the single-setup shape"},
        {name: "evidence/../../etc/x.md", content: "must never be written"},
        {name: "evidence/a/b/c.md", content: "must never be written"},
        {name: "/evidence/leading-slash.md", content: "must never be written"},
        {name: "evidence/notes.txt", content: "must never be written"}
      ]
    }
  }')"
  start_mock "$scenario" || { end_case; return; }
  setup_env
  make_repos

  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"

  local dir="$WORKSPACE/$FOLDER/releases/2026-08-20-2.31.0"
  check_file "first setup's evidence file at its exact path" "$dir/evidence/production-mcp/cr1c07-2.31.0.md"
  check_file "second setup's evidence file at its exact path" "$dir/evidence/agent-sdk/cr1c07-2.31.0.md"
  check_file "the flat name still lands directly under evidence/" "$dir/evidence/tm1t04-2.31.0.md"
  check_grep "the content is the delivered content" "per setup, second setup" "$dir/evidence/agent-sdk/cr1c07-2.31.0.md"

  check_no_path "the traversal attempt wrote nothing" "$WORKSPACE/$FOLDER/etc"
  check_no_path "a deeper path wrote nothing" "$dir/evidence/a"
  check_no_path "a leading slash wrote nothing" "$dir/evidence/leading-slash.md"
  check_no_path "a name that is not .md wrote nothing" "$dir/evidence/notes.txt"

  check_eq "exactly the three named files are on disk" "3" \
    "$(find "$dir/evidence" -type f | wc -l | tr -d ' ')"
  check_grep "the log states what was written against what was served" "Wrote 3 of 7 evidence file(s)" "$CASE_TMP/run.log"
  check_grep "the refused name is named in the log" "evidence/../../etc/x.md" "$CASE_TMP/run.log"
  check_grep "the loss is an error, not a warning" "::error::refusing an evidence entry" "$CASE_TMP/run.log"

  # The report still reaches the repository; the job still ends red.
  check_eq "the report is committed even though evidence was refused" \
    "Verging Memory CI: report for 2.31.0 ($rid): Not ready: 1 accuracy failure [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  run_step set_outputs.sh
  check_exit "the run ends red when a named evidence file is missing" 1 "$STEP_EXIT"
  check_grep "outputs are still set" "release_id=$rid" "$GITHUB_OUTPUT"
  check_grep "the job summary says which report is short of files" "did not reach the report folder" "$GITHUB_STEP_SUMMARY"
  end_case
}

case_vocabulary() {
  begin_case "vocabulary sweep: the banned words and em dashes appear nowhere"
  # The banned strings are assembled from pieces so this file never contains
  # them itself.
  local w1 w2 w3 w4 em hits ok=0
  w1="cap"; w1="${w1}ture"
  w2="re";  w2="${w2}play"
  w3="pre"; w3="${w3}compute"
  w4="locked"; w4="${w4} state"
  em="$(printf '\xe2\x80\x94')"
  for w in "$w1" "$w2" "$w3" "$w4" "$em"; do
    hits="$(grep -rIni --exclude-dir=.git -F -- "$w" "$ROOT" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      note_fail "found a banned string in the repository:"
      printf '%s\n' "$hits" | sed 's/^/      /'
      ok=1
    fi
  done
  if [ "$ok" = "0" ]; then
    say "    ok: no banned words and no em dashes anywhere in the repository"
  fi
  end_case
}

posted_body() { # echoes the body of the first POST to /v1/releases
  jq -rs '[.[] | select(.method == "POST")][0].body' "$MOCK_DIR/requests.log"
}

case_single_setup_payload() {
  begin_case "a single agent setup sends a one-item agent_setups array, never a singular environment"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  # setup_env sets VERGING_AGENT_SETUPS=staging-mcp (one name = a one-item list).
  run_step resolve_inputs.sh; check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh
  run_step run_release.sh;    check_exit "run_release exits 0" 0 "$STEP_EXIT"

  local posted; posted="$(posted_body)"
  check_eq "a one-item agent_setups array is sent" '["staging-mcp"]' "$(printf '%s' "$posted" | jq -c '.agent_setups')"
  check_eq "no singular environment field is sent" "null" "$(printf '%s' "$posted" | jq -r '.environment')"
  check_eq "no suites by default (all chosen suites)" "null" "$(printf '%s' "$posted" | jq -r '.suites')"
  end_case
}

case_multi_setup_payload() {
  begin_case "agent_setups A,B sends an agent_setups array and no singular environment"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  unset VERGING_ENVIRONMENT
  export VERGING_AGENT_SETUPS="staging-mcp, prod-mcp"
  run_step resolve_inputs.sh; check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh
  run_step run_release.sh;    check_exit "run_release exits 0" 0 "$STEP_EXIT"

  local posted; posted="$(posted_body)"
  check_eq "the agent_setups array matches the API's expected shape" '["staging-mcp","prod-mcp"]' "$(printf '%s' "$posted" | jq -c '.agent_setups')"
  check_eq "no singular environment is sent" "null" "$(printf '%s' "$posted" | jq -r '.environment')"
  check_eq "the separator was trimmed, not sent as a name" "2" "$(printf '%s' "$posted" | jq -r '.agent_setups | length')"
  check_eq "no suites by default for multi-setup (all chosen suites)" "null" "$(printf '%s' "$posted" | jq -r '.suites')"
  check_grep "the job summary lists the setups" "| agent setups | \`staging-mcp, prod-mcp\` |" "$GITHUB_STEP_SUMMARY"
  end_case
}

case_multi_setup_newline_and_suite_scope() {
  begin_case "agent_setups split on newlines too, and a scoped suite still passes through"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  unset VERGING_ENVIRONMENT
  # Newline separated, with a blank line and a trailing comma that must not
  # become names of their own.
  export VERGING_AGENT_SETUPS=$'staging-mcp\nprod-mcp,\n'
  export VERGING_SUITES="onboarding"
  run_step resolve_inputs.sh; check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh
  run_step run_release.sh;    check_exit "run_release exits 0" 0 "$STEP_EXIT"

  local posted; posted="$(posted_body)"
  check_eq "newline and comma separators both split the list" '["staging-mcp","prod-mcp"]' "$(printf '%s' "$posted" | jq -c '.agent_setups')"
  check_eq "the release is scoped to the one suite" '["onboarding"]' "$(printf '%s' "$posted" | jq -c '.suites')"
  end_case
}

case_multi_setup_display_names() {
  begin_case "agent_setups accepts display names with internal spaces, and refuses a bad name without refusing the separator"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  unset VERGING_ENVIRONMENT
  export VERGING_AGENT_SETUPS="Production MCP,Agent SDK"
  run_step resolve_inputs.sh; check_exit "two display names are accepted" 0 "$STEP_EXIT"
  run_step reconcile.sh
  run_step run_release.sh
  local posted; posted="$(posted_body)"
  check_eq "display names travel verbatim in the array" '["Production MCP","Agent SDK"]' "$(printf '%s' "$posted" | jq -c '.agent_setups')"

  # A bad name in the list is refused; the comma itself is never the problem.
  export VERGING_AGENT_SETUPS="staging-mcp,bad name!"
  run_step resolve_inputs.sh; check_exit "a bad name in the list is refused" 1 "$STEP_EXIT"
  check_grep "the refusal names the bad setup, not the separator" "agent setup 'bad name!' is not valid" "$CASE_TMP/run.log"

  # A repeated name is refused, matching the API.
  export VERGING_AGENT_SETUPS="staging-mcp,staging-mcp"
  run_step resolve_inputs.sh; check_exit "a repeated name is refused" 1 "$STEP_EXIT"
  check_grep "the refusal explains the repeat" "names an agent setup more than once" "$CASE_TMP/run.log"
  end_case
}

case_environment_missing_refused() {
  begin_case "agent_setups is optional, while the retired environments input fails clearly"
  MOCK_PORT="0"
  setup_env
  make_repos

  # Not set means account defaults. The onboarding wiring-check step relies on
  # this before the final integration step adds trigger-specific setup scope.
  unset VERGING_AGENT_SETUPS
  run_step resolve_inputs.sh
  check_exit "resolve_inputs accepts omitted agent_setups" 0 "$STEP_EXIT"
  check_eq "omitted agent_setups resolves to an empty selection" "[]" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/agent_setups_json")"

  # Only separators is the same omission after normalization.
  export VERGING_AGENT_SETUPS=" , "
  run_step resolve_inputs.sh
  check_exit "resolve_inputs accepts an empty normalized agent_setups list" 0 "$STEP_EXIT"
  check_eq "separator-only agent_setups resolves to an empty selection" "[]" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/agent_setups_json")"

  # The retired name is never an alias. It is accepted by action.yml only so
  # the migration failure is explicit rather than a GitHub metadata warning.
  export VERGING_LEGACY_ENVIRONMENTS="staging-mcp"
  run_step resolve_inputs.sh
  check_exit "resolve_inputs rejects the retired environments input" 1 "$STEP_EXIT"
  check_grep "the refusal gives the exact breaking migration" "replace environments with agent_setups; no compatibility alias is provided" "$CASE_TMP/run.log"

  export VERGING_MODE="sync"
  run_step resolve_inputs.sh
  check_exit "sync mode also rejects the retired environments input" 1 "$STEP_EXIT"
  end_case
}

# ---------- the pending record: a job that stops waiting ----------

pending_notice() { # $1 release id, $2 last status: the exact notice
  printf '%s' "::notice::Verging Labs is still testing release $1 (last status: $2). This job stops waiting; your next push or the sync job commits the report when it is ready. To wait longer, set poll_timeout_minutes."
}

# new_job: a later job in the same repository. Fresh step state, outputs,
# summary, gh log and run log; the workspace and the origin stay as the last
# job left them.
new_job() {
  rm -rf "$RUNNER_TEMP/verging-memory-ci-state"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$GH_SHIM_LOG"
  cat "$CASE_TMP/run.log" >> "$CASE_TMP/run-earlier.log"
  : > "$CASE_TMP/run.log"
}

# set_scenario JSON: swap the mock's script; forget served statuses and
# recorded requests.
set_scenario() {
  printf '%s' "$1" > "$MOCK_DIR/scenario.json"
  rm -f "$MOCK_DIR"/status-*.count
  : > "$MOCK_DIR/requests.log"
}

seed_pending_release() { # $1 release id, $2 vendor_version, $3 submitted_at: a pending record an earlier job committed
  # Deliberately the shape an earlier version of the action wrote (the setups
  # under "environments"): every reader must still take it.
  mkdir -p "$WORKSPACE/$FOLDER/releases"
  jq -n --arg rid "$1" --arg v "$2" --arg at "$3" \
    '{($rid): {vendor_version: $v, environments: ["staging-mcp"], submitted_at: $at, status: "running"}}' \
    > "$WORKSPACE/$FOLDER/releases/pending.json"
  cp "$ROOT/scripts/folder-readme.md" "$WORKSPACE/$FOLDER/README.md"
  (
    cd "$WORKSPACE"
    git add "$FOLDER"
    git commit -qm "Verging Memory CI: release $2 ($1) is pending; the report follows [skip ci]"
    git push -q origin HEAD:main
  )
}

case_timeout_pending() {
  begin_case "the deadline passes: the job ends green with the release on record as pending, and a later sync job commits the report"
  local rid="run_20260826_5e6f7a8b9c0d"
  start_mock "$(happy_scenario "$rid" | jq --arg rid "$rid" '.statuses = [{release_id: $rid, status: "running", updated_at: "2026-08-15T08:40:00Z"}]')" || { end_case; return; }
  setup_env
  make_repos
  export VERGING_POLL_TIMEOUT_MINUTES="0"

  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0 when the deadline passes" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_EVENT_PATH="$CASE_TMP/event.json"
  jq -n '{pull_request: {number: 12, head: {sha: "abc123def4567890abc123def4567890abc123de"}}}' > "$GITHUB_EVENT_PATH"
  run_step surfaces.sh;        check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh;     check_exit "set_outputs exits 0: the job is green" 0 "$STEP_EXIT"

  check_grep "the exact notice is emitted" "$(pending_notice "$rid" running)" "$CASE_TMP/run.log"
  check_no_grep "no error anywhere in the job" "::error::" "$CASE_TMP/run.log"
  check_eq "the status was asked for once, then the job stopped waiting" "1" "$(cat "$MOCK_DIR/status-$rid.count")"
  local pending="$WORKSPACE/$FOLDER/releases/pending.json"
  check_file "the pending record is written" "$pending"
  check_eq "the pending entry: vendor_version, agent_setups, submitted_at, last status" \
    '{"vendor_version":"2.31.0","agent_setups":["staging-mcp"],"submitted_at":"2026-08-15T08:25:59.868Z","status":"running"}' \
    "$(jq -c --arg rid "$rid" '.[$rid]' "$pending")"
  check_no_path "no release directory: there is no report yet" "$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  check_no_path "no latest/: there is no report yet" "$WORKSPACE/$FOLDER/latest"
  check_no_path "no index row without a report" "$WORKSPACE/$FOLDER/releases/index.md"
  check_file "folder README written" "$WORKSPACE/$FOLDER/README.md"
  check_eq "the pending record is committed and pushed" \
    "Verging Memory CI: release 2.31.0 ($rid) is pending; the report follows [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "the commit carries the pending record" "$FOLDER/releases/pending.json" <(git -C "$ORIGIN" show --name-only --format= main)
  check_grep "output release_id" "release_id=$rid" "$GITHUB_OUTPUT"
  check_grep "output verdict is Pending" "verdict=Pending" "$GITHUB_OUTPUT"
  check_eq "output report_path is empty" "report_path=" "$(grep '^report_path=' "$GITHUB_OUTPUT")"
  check_grep "check run title says Report pending" "output\[title\]=Report\ pending" "$GH_SHIM_LOG"
  check_grep "check run conclusion is neutral" "conclusion=neutral" "$GH_SHIM_LOG"
  check_eq "no check run concludes failure" "0" "$(grep -c 'conclusion=failure' "$GH_SHIM_LOG")"
  check_grep "the check run says it in one line" "output\[summary\]=Verging\ Labs\ is\ still\ testing\ release" "$GH_SHIM_LOG"
  check_grep "the check run line names the last status and what happens next" "last\ status:\ running\).\ Your\ next\ push\ or\ the\ sync\ job\ commits\ the\ report\ when\ it\ is\ ready." "$GH_SHIM_LOG"
  check_grep "the pull request comment says report pending in one line" "**Verging Memory CI: report pending.** Verging Labs is still testing release" "$GH_SHIM_LOG"
  check_no_grep "the comment links no report" "[Read the report]" "$GH_SHIM_LOG"
  check_grep "job summary says the report is pending" "### Report pending" "$GITHUB_STEP_SUMMARY"
  check_grep "action.yml documents the Pending verdict" 'Pending\" when the job stopped waiting before the report was ready' "$ROOT/action.yml"
  check_grep "action.yml commits on every path but a cancel" "if: \${{ !cancelled() && inputs.mode != 'sync' }}" "$ROOT/action.yml"

  # A later sync job: the report is ready now.
  new_job
  set_scenario "$(happy_scenario "$rid" | jq --arg rid "$rid" '.statuses = [{release_id: $rid, status: "report_ready", updated_at: "2026-08-15T10:31:00Z", corrections_due_by: "2026-08-18"}]')"
  export GITHUB_EVENT_NAME="push"
  unset GITHUB_EVENT_PATH VERGING_AGENT_SETUPS VERGING_POLL_TIMEOUT_MINUTES
  export VERGING_MODE="sync"
  run_step resolve_inputs.sh;  check_exit "sync: resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "sync: reconcile exits 0" 0 "$STEP_EXIT"
  check_grep "the reconcile pass found the pending release" "Release $rid (2.31.0) is on record as pending since 2026-08-15T08:25:59.868Z (last status: running)" "$CASE_TMP/run.log"
  local dir="$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  check_file "REPORT.md written by the sync job" "$dir/REPORT.md"
  check_file "diff.json written" "$dir/diff.json"
  check_file "release.json written" "$dir/release.json"
  check_file "evidence written at its path" "$dir/evidence/production-mcp/cr1c07-2.31.0.md"
  check_eq "the folder holds the preliminary report" "preliminary" "$(jq -r '.stage' "$dir/diff.json")"
  check_grep "the index row is the one a fresh delivery writes" "| 2026-08-15 | 2.31.0 | [$rid](2026-08-15-2.31.0/REPORT.md) | Ready | preliminary |" "$WORKSPACE/$FOLDER/releases/index.md"
  check_dirs_equal "latest/ is the release directory" "$dir" "$WORKSPACE/$FOLDER/latest"
  check_no_path "the pending record is cleared (the file goes with its last entry)" "$pending"
  check_eq "committed exactly as a fresh delivery" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_eq "the pending record is gone from the branch" "" "$(git -C "$ORIGIN" ls-tree -r --name-only main | grep -F pending.json || true)"
  check_eq "nothing was submitted by the sync job" "0" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  check_no_grep "no error in the sync job" "::error::" "$CASE_TMP/run.log"
  check_grep "the sync job summary carries the verdict" "### Release verdict: Ready" "$GITHUB_STEP_SUMMARY"
  run_step run_release.sh;     check_exit "run_release is a no-op in sync mode" 0 "$STEP_EXIT"
  end_case
}

case_pending_running_then_failed() {
  begin_case "a pending release still being tested stays on record; one that failed gets its index line and is cleared, and the job stays green"
  local rid="run_20260826_5e6f7a8b9c0d"
  start_mock "$(jq -n --arg rid "$rid" '{statuses: [
    {release_id: $rid, status: "running", updated_at: "2026-08-15T09:00:00Z"},
    {release_id: $rid, status: "failed", failure: "we could not reach your endpoint from the agent environment"}
  ]}')" || { end_case; return; }
  setup_env
  make_repos
  seed_pending_release "$rid" "2.31.0" "2026-08-15T08:25:59.868Z"
  unset VERGING_AGENT_SETUPS
  export VERGING_MODE="sync"
  local pending="$WORKSPACE/$FOLDER/releases/pending.json"

  # 1. Still being tested: left on record, nothing committed.
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0 while the release is still being tested" 0 "$STEP_EXIT"
  check_grep "the log says it is still being tested" "Release $rid (2.31.0) is still being tested (status: running); leaving it on record as pending." "$CASE_TMP/run.log"
  check_file "the pending record stays" "$pending"
  check_eq "the entry is untouched" "running" "$(jq -r --arg rid "$rid" '.[$rid].status' "$pending")"
  check_eq "nothing was committed" \
    "Verging Memory CI: release 2.31.0 ($rid) is pending; the report follows [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"

  # 2. Failed on the Verging side: the index says so, the entry goes, green.
  new_job
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0 on a failed pending release: no red job" 0 "$STEP_EXIT"
  check_no_grep "no error anywhere in the job" "::error::" "$CASE_TMP/run.log"
  check_grep "the failure is a warning with the failure text" "::warning::release $rid (2.31.0) failed on the Verging side: we could not reach your endpoint from the agent environment" "$CASE_TMP/run.log"
  check_grep "the voided copy is printed" "The release is voided; voided tests are never billed." "$CASE_TMP/run.log"
  check_no_path "the pending record is cleared" "$pending"
  check_grep "the index notes the failure on the release's own row" "| 2026-08-15 | 2.31.0 | $rid | Failed: we could not reach your endpoint from the agent environment | failed |" "$WORKSPACE/$FOLDER/releases/index.md"
  check_no_path "no release directory for a failed release" "$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  check_no_path "no latest/ for a failed release" "$WORKSPACE/$FOLDER/latest"
  check_eq "the failure line is committed and pushed" \
    "Verging Memory CI: release 2.31.0 ($rid) failed on the Verging side [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "the job summary says which release failed" "failed on the Verging side" "$GITHUB_STEP_SUMMARY"
  end_case
}

case_fetch_only_pending() {
  begin_case "fetch_only_release_id on a release still being tested: green, on record as pending from its status body"
  local rid="run_20260810_ffeeddccbbaa"
  start_mock "$(jq -n --arg rid "$rid" '{status_by_id: {($rid): [
    {release_id: $rid, status: "running", vendor_version: "2.30.9", received_at: "2026-08-10T09:00:00.000Z",
     environments: {count: 1, agent_setups: ["Production MCP"], suites: ["Core Recall"]}}
  ]}}')" || { end_case; return; }
  setup_env
  make_repos
  export VERGING_FETCH_ONLY_RELEASE_ID="$rid"
  export VERGING_POLL_TIMEOUT_MINUTES="0"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 0 when the deadline passes" 0 "$STEP_EXIT"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  run_step surfaces.sh;        check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  run_step set_outputs.sh;     check_exit "set_outputs exits 0: the job is green" 0 "$STEP_EXIT"

  check_eq "nothing was submitted" "0" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  check_grep "the exact notice is emitted" "$(pending_notice "$rid" running)" "$CASE_TMP/run.log"
  check_no_grep "no error anywhere in the job" "::error::" "$CASE_TMP/run.log"
  check_eq "the pending entry comes from the status body" \
    '{"vendor_version":"2.30.9","agent_setups":["Production MCP"],"submitted_at":"2026-08-10T09:00:00.000Z","status":"running"}' \
    "$(jq -c --arg rid "$rid" '.[$rid]' "$WORKSPACE/$FOLDER/releases/pending.json")"
  check_grep "output verdict is Pending" "verdict=Pending" "$GITHUB_OUTPUT"
  check_eq "the pending record is committed with the status body's version" \
    "Verging Memory CI: release 2.30.9 ($rid) is pending; the report follows [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "check run conclusion is neutral" "conclusion=neutral" "$GH_SHIM_LOG"

  # A pending record an earlier version of the action wrote, keyed
  # "environments": it is read as agent_setups, and once its status is
  # brought up to date it is rewritten under the current name.
  new_job
  local old="run_20260809_0011223344cc"
  set_scenario "$(jq -n --arg old "$old" '{status_by_id: {($old): [
    {release_id: $old, status: "running", vendor_version: "2.30.8", received_at: "2026-08-09T09:00:00.000Z",
     environments: {count: 1, agent_setups: ["staging-mcp"], suites: ["Core Recall"]}}
  ]}}')"
  seed_pending_release "$old" "2.30.8" "2026-08-09T09:00:00.000Z"
  check_grep "the seeded record uses the old key" '"environments"' "$WORKSPACE/$FOLDER/releases/pending.json"
  check_eq "pending_get reads the old key as agent_setups" \
    '{"vendor_version":"2.30.8","agent_setups":["staging-mcp"],"submitted_at":"2026-08-09T09:00:00.000Z","status":"running"}' \
    "$(cd "$WORKSPACE" && set +u && source "$ROOT/scripts/lib.sh" && pending_get "$FOLDER" "$old")"
  export VERGING_FETCH_ONLY_RELEASE_ID="$old"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile reads the old record and exits 0" 0 "$STEP_EXIT"
  check_grep "the reconcile pass read the old record" "Release $old (2.30.8) is on record as pending since 2026-08-09T09:00:00.000Z (last status: running)" "$CASE_TMP/run.log"
  run_step run_release.sh;     check_exit "run_release exits 0 when the deadline passes" 0 "$STEP_EXIT"
  check_eq "the old record is rewritten under agent_setups" \
    '{"vendor_version":"2.30.8","agent_setups":["staging-mcp"],"submitted_at":"2026-08-09T09:00:00.000Z","status":"running"}' \
    "$(jq -c --arg id "$old" '.[$id]' "$WORKSPACE/$FOLDER/releases/pending.json")"
  check_eq "exactly one entry, under its release id" "1" "$(jq 'length' "$WORKSPACE/$FOLDER/releases/pending.json")"
  check_no_grep "the old key is gone from the file" '"environments"' "$WORKSPACE/$FOLDER/releases/pending.json"
  unset VERGING_FETCH_ONLY_RELEASE_ID
  end_case
}

case_pending_after_fetch_failure() {
  begin_case "a job that fails after the receipt still commits the pending record, and the next release job collects the report first"
  local rid="run_20260815_186efbad9769"
  # report_ready, but the report route refuses: the job is red, as before.
  start_mock "$(happy_scenario "$rid" | jq --arg rid "$rid" 'del(.report) | .statuses = [{release_id: $rid, status: "report_ready", corrections_due_by: "2026-08-18"}]')" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  run_step run_release.sh;     check_exit "run_release exits 1 when the report cannot be fetched" 1 "$STEP_EXIT"
  check_grep "the error names the report route" "::error::GET /v1/releases/$rid/report returned HTTP 409" "$CASE_TMP/run.log"
  run_step commit_push.sh;     check_exit "commit_push exits 0" 0 "$STEP_EXIT"
  check_eq "only the pending record is committed" \
    "Verging Memory CI: release 2.31.0 ($rid) is pending; the report follows [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_eq "the commit carries the pending record and nothing else" "$FOLDER/releases/pending.json" "$(git -C "$ORIGIN" show --name-only --format= main)"
  check_eq "the entry carries the last status seen" "report_ready" "$(jq -r --arg rid "$rid" '.[$rid].status' "$WORKSPACE/$FOLDER/releases/pending.json")"

  # The next push: a release job whose reconcile pass collects the report
  # before this job's own release is resolved any further.
  new_job
  set_scenario "$(happy_scenario "$rid" | jq --arg rid "$rid" '.statuses = [{release_id: $rid, status: "report_ready", corrections_due_by: "2026-08-18"}]')"
  export VERGING_VENDOR_VERSION="2.32.0"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  local dir="$WORKSPACE/$FOLDER/releases/2026-08-15-2.31.0"
  check_file "the pending release's report is written" "$dir/REPORT.md"
  check_eq "the pending release's report is committed as a fresh delivery" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready [skip ci]" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_no_path "the pending record is cleared" "$WORKSPACE/$FOLDER/releases/pending.json"
  check_eq "this job's own vendor_version is left as resolved" "2.32.0" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/vendor_version")"
  check_eq "this job carries no release id from the collected report" "" "$(cat "$RUNNER_TEMP/verging-memory-ci-state/release_id" 2>/dev/null || true)"
  check_eq "nothing was submitted by the reconcile pass" "0" "$(jq -rs '[.[] | select(.method == "POST")] | length' "$MOCK_DIR/requests.log")"
  unset VERGING_VENDOR_VERSION
  end_case
}

case_pending_older_than_latest() {
  begin_case "a pending report older than the newest on record: its index row goes in date order and latest/ stays with the newer release"
  local old="run_20260810_0123456789ab" newer="run_20260814_aaaabbbbcccc"
  local old_md newer_md
  old_md="$(make_report_md "Larkspur 2.29.0" "Ready" "Preliminary report")"
  newer_md="$(make_report_md "Larkspur 2.30.0" "Not ready: 2 accuracy failures" "Preliminary report")"
  start_mock "$(jq -n --arg old "$old" --arg newer "$newer" --arg old_md "$old_md" --arg newer_md "$newer_md" '{
    status_by_id: {($old): [{release_id: $old, status: "report_ready", received_at: "2026-08-10T09:00:00.000Z"}]},
    report_by_id: {
      ($old): {release_id: $old, status: "report_ready", vendor_version: "2.29.0", scope: {suites: ["core-recall"]},
               corrections_due_by: "2026-08-11", report_markdown: $old_md,
               diff: {format: "release-diff/v1", release_verdict: "ready", stage: "preliminary"}, evidence: []},
      ($newer): {release_id: $newer, status: "report_ready", vendor_version: "2.30.0", scope: {suites: ["core-recall"]},
               corrections_due_by: "2026-08-17", report_markdown: $newer_md,
               diff: {format: "release-diff/v1", release_verdict: "not_ready", stage: "preliminary"}, evidence: []}
    }
  }')" || { end_case; return; }
  setup_env
  make_repos
  seed_preliminary_release "$newer"
  seed_pending_release "$old" "2.29.0" "2026-08-10T09:00:00.000Z"
  unset VERGING_AGENT_SETUPS
  export VERGING_MODE="sync"
  run_step resolve_inputs.sh;  check_exit "resolve_inputs exits 0" 0 "$STEP_EXIT"
  run_step reconcile.sh;       check_exit "reconcile exits 0" 0 "$STEP_EXIT"
  local index="$WORKSPACE/$FOLDER/releases/index.md"
  check_file "the older release's report is written" "$WORKSPACE/$FOLDER/releases/2026-08-10-2.29.0/REPORT.md"
  check_grep "the older release has its row" "| 2026-08-10 | 2.29.0 | [$old](2026-08-10-2.29.0/REPORT.md) | Ready | preliminary |" "$index"
  check_eq "the index stays oldest first" "1" \
    "$([ "$(grep -nF "[$old](" "$index" | cut -d: -f1)" -lt "$(grep -nF "[$newer](" "$index" | cut -d: -f1)" ] && echo 1 || echo 0)"
  check_eq "latest/ stays with the newer release" "$newer" "$(jq -r '.release_id' "$WORKSPACE/$FOLDER/latest/release.json")"
  check_grep "the log says why latest/ was left" "latest/ left as it is: a newer release's report is already on record." "$CASE_TMP/run.log"
  check_no_path "the pending record is cleared" "$WORKSPACE/$FOLDER/releases/pending.json"
  check_grep "the newer release's preliminary report is left in place (no final yet)" "The final report for $newer is not out yet" "$CASE_TMP/run.log"
  end_case
}

# ---------- run ----------

say "Verging Memory CI action test harness"
say "Repository under test: $ROOT"
export PATH="$TESTDIR/shims:$PATH"

case_happy_path
case_single_setup_payload
case_multi_setup_payload
case_multi_setup_newline_and_suite_scope
case_multi_setup_display_names
case_environment_missing_refused
case_name_rules
case_held
case_failed
case_fetch_only
case_wiring_check_input
case_not_set_up_fallback
case_other_409_fails
case_evidence_paths
case_reconcile
case_sync_mode
case_timeout_pending
case_pending_running_then_failed
case_fetch_only_pending
case_pending_after_fetch_failure
case_pending_older_than_latest
case_push_retry
case_push_refused
case_reconcile_push_refused
case_fallback_pull_request_opt_in
case_surfaces
case_vocabulary

say ""
say "==============================="
say "Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  say "Failing cases:"
  for c in "${FAILED_CASES[@]}"; do say "  - $c"; done
  exit 1
fi
say "All cases passed."
exit 0
