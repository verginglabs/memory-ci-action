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
  export VERGING_ENVIRONMENT="staging-mcp"
  export VERGING_API_BASE="http://127.0.0.1:${MOCK_PORT:-0}"
  # The same value action.yml declares as the input default; the happy path
  # case checks the two stay in step.
  export VERGING_SUITES="core-recall,preference-adherence,truth-maintenance"
  unset VERGING_VENDOR_VERSION VERGING_ENDPOINT VERGING_FOLDER 2>/dev/null
  unset VERGING_PRODUCT_NAME VERGING_FETCH_ONLY_RELEASE_ID VERGING_POLL_TIMEOUT_MINUTES 2>/dev/null
  unset VERGING_DEFAULT_BRANCH GH_PR_LIST_OUTPUT GH_COMMENTS_OUTPUT GH_SHIM_FAIL 2>/dev/null
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
  md="$(make_report_md "Larkspur 2.31.0" "Ready" "Preliminary report (the final report follows by next business day)")"
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
  check_eq "submitted endpoint defaults to the standing configuration" "cfg:standing" "$(printf '%s' "$posted" | jq -r '.endpoint')"
  check_eq "submitted suites default to the three suites" "core-recall,preference-adherence,truth-maintenance" "$(printf '%s' "$posted" | jq -r '.suites | join(",")')"
  check_eq "submitted environment" "staging-mcp" "$(printf '%s' "$posted" | jq -r '.environment')"
  check_eq "no product_name submitted when the input is empty" "null" "$(printf '%s' "$posted" | jq -r '.product_name')"
  check_grep "action.yml declares the same suites default" 'default: "core-recall,preference-adherence,truth-maintenance"' "$ROOT/action.yml"
  check_grep "action.yml declares the same endpoint default" 'default: "cfg:standing"' "$ROOT/action.yml"

  check_eq "report commit is on the triggering branch" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready" \
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
  export VERGING_ENVIRONMENT="Production MCP"
  run_step resolve_inputs.sh
  check_exit "a two-word product name and agent setup are accepted" 0 "$STEP_EXIT"
  check_eq "the environment is stored as the customer named it" "Production MCP" \
    "$(cat "$RUNNER_TEMP/verging-memory-ci-state/environment")"
  check_eq "the product name is stored as the customer named it" "Larkspur Memory" \
    "$(cat "$RUNNER_TEMP/verging-memory-ci-state/product_name")"

  export VERGING_PRODUCT_NAME="bad name!"
  run_step resolve_inputs.sh
  check_exit "a name the API refuses is refused here first" 1 "$STEP_EXIT"
  check_grep "the error names product_name" "product_name 'bad name!' is not valid" "$CASE_TMP/run.log"
  check_grep "the fix wording is the API's own" "letters, digits, spaces, dots, underscores, plus signs, and hyphens only; single spaces between words, none at the start or the end" "$CASE_TMP/run.log"

  export VERGING_PRODUCT_NAME="Larkspur.Memory-2+beta_1"
  export VERGING_ENVIRONMENT=".."
  run_step resolve_inputs.sh
  check_exit "an agent setup whose folder would be the parent directory is refused" 1 "$STEP_EXIT"
  check_grep "the refusal says what it is about" "cannot name the folder its evidence files go in" "$CASE_TMP/run.log"

  export VERGING_ENVIRONMENT="staging-mcp"
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
  check_no_path "no report folder written on a failed release" "$WORKSPACE/$FOLDER"
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
    "Verging Memory CI: report for 2.30.9 ($rid): Ready" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
  check_grep "output release_id" "release_id=$rid" "$GITHUB_OUTPUT"
  end_case
}

seed_preliminary_release() { # $1 release id; seeds and pushes a preliminary report
  local rid="$1" dir="$WORKSPACE/$FOLDER/releases/2026-08-14-2.30.0"
  mkdir -p "$dir/evidence"
  make_report_md "Larkspur 2.30.0" "Not ready: 2 accuracy failures" "Preliminary report (the final report follows by next business day)" > "$dir/REPORT.md"
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
    "Verging Memory CI: final report for 2.30.0 ($rid)" \
    "$(git -C "$ORIGIN" log -1 --format=%s main)"
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

case_push_fallback() {
  begin_case "a rejecting remote falls back to the reports branch and a pull request"
  local rid="run_20260815_186efbad9769"
  start_mock "$(happy_scenario "$rid")" || { end_case; return; }
  setup_env
  make_repos
  run_step resolve_inputs.sh
  run_step reconcile.sh
  run_step run_release.sh
  check_exit "run_release exits 0" 0 "$STEP_EXIT"

  # The remote now rejects every push to main (a protected branch would).
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

  run_step commit_push.sh
  check_exit "commit_push exits 0 even though the push failed" 0 "$STEP_EXIT"
  check_grep "the log says plainly the direct push failed" "could not push the report commit to main after 3 attempts" "$CASE_TMP/run.log"
  check_grep "the log says the pull request path happened" "a pull request into main was opened" "$CASE_TMP/run.log"
  check_eq "the reports branch carries the report commit" \
    "Verging Memory CI: report for 2.31.0 ($rid): Ready" \
    "$(git -C "$ORIGIN" log -1 --format=%s verging-memory-ci/reports)"
  check_grep "gh looked for an existing pull request" "pr list --head verging-memory-ci/reports" "$GH_SHIM_LOG"
  check_grep "gh opened the pull request with the ruled title" "pr create --head verging-memory-ci/reports --base main --title Verging\\ Memory\\ CI\\ reports" "$GH_SHIM_LOG"

  # A later run finds the pull request already open and does not open another.
  printf '\n' >> "$WORKSPACE/$FOLDER/releases/index.md"
  export GH_PR_LIST_OUTPUT="7"
  run_step commit_push.sh
  check_exit "the second commit_push exits 0" 0 "$STEP_EXIT"
  check_eq "no second pull request opened" "1" "$(grep -c 'pr create' "$GH_SHIM_LOG")"
  check_grep "the log names the open pull request" "the open pull request #7 into main now carries it" "$CASE_TMP/run.log"
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
  begin_case "check run and comment: neutral is never a failure, one comment per pull request"
  MOCK_PORT="0"
  setup_env
  make_repos
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_HEAD_REF="feature-x"
  export GITHUB_EVENT_PATH="$CASE_TMP/event.json"
  jq -n '{pull_request: {number: 12, head: {sha: "abc123def4567890abc123def4567890abc123de"}}}' > "$GITHUB_EVENT_PATH"

  seed_surfaces_state "Not ready: 1 accuracy failure"
  run_step surfaces.sh
  check_exit "surfaces exits 0" 0 "$STEP_EXIT"
  check_grep "check posted on the pull request head commit" "head_sha=abc123def4567890abc123def4567890abc123de" "$GH_SHIM_LOG"
  check_grep "Not ready posts conclusion neutral" "conclusion=neutral" "$GH_SHIM_LOG"
  check_grep "comment created on the pull request" "issues/12/comments" "$GH_SHIM_LOG"
  check_grep "comment body starts with the marker" "<!-- verging-memory-ci -->" "$GH_SHIM_LOG"
  check_grep "comment body carries the release id" "run_20260815_186efbad9769" "$GH_SHIM_LOG"
  check_grep "comment links the committed report" "/acme/widget/blob/feature-x/Verging%20Memory%20CI/releases/2026-08-15-2.31.0/REPORT.md" "$GH_SHIM_LOG"

  # A later run updates the same comment in place.
  export GH_COMMENTS_OUTPUT="98765"
  run_step surfaces.sh
  check_exit "surfaces exits 0 on the update pass" 0 "$STEP_EXIT"
  check_grep "the existing comment is updated in place" "issues/comments/98765 -X PATCH" "$GH_SHIM_LOG"
  check_eq "only one comment was ever created" "1" "$(grep -c 'issues/12/comments -X POST' "$GH_SHIM_LOG")"
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
  md="$(make_report_md "Larkspur 2.31.0" "Not ready: 1 accuracy failure" "Preliminary report (the final report follows by next business day)")"
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
    "Verging Memory CI: report for 2.31.0 ($rid): Not ready: 1 accuracy failure" \
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

# ---------- run ----------

say "Verging Memory CI action test harness"
say "Repository under test: $ROOT"
export PATH="$TESTDIR/shims:$PATH"

case_happy_path
case_name_rules
case_held
case_failed
case_fetch_only
case_evidence_paths
case_reconcile
case_push_retry
case_push_fallback
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
