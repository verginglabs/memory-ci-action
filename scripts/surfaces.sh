#!/usr/bin/env bash
# The two run surfaces beyond the folder: a check run on the tested commit,
# and on pull requests one comment (updated in place on later runs).
#
# Ruled behavior: the check is NEVER a failure (never a red X). A Ready
# verdict posts conclusion success; Not ready and refusals post conclusion
# neutral. And nothing in this script may fail the job: every failure here
# is a warning, because the report itself is already committed.
set -uo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

verdict="$(state_get verdict)"
release_id="$(state_get release_id)"
report_path="$(state_get report_path)"

if [ -z "$release_id" ] || [ -z "$verdict" ]; then
  echo "No report this run; no check or comment to post."
  exit 0
fi

repo="${GITHUB_REPOSITORY:-}"
event="${GITHUB_EVENT_NAME:-}"
event_path="${GITHUB_EVENT_PATH:-}"

head_sha="${GITHUB_SHA:-}"
pr_number=""
if [ "$event" = "pull_request" ] && [ -n "$event_path" ] && [ -f "$event_path" ]; then
  s="$(jq -r '.pull_request.head.sha // empty' "$event_path" 2>/dev/null || true)"
  [ -n "$s" ] && head_sha="$s"
  pr_number="$(jq -r '.pull_request.number // .number // empty' "$event_path" 2>/dev/null || true)"
fi

# wiring_line PAGE_REF: the one line both surfaces say when this run
# performed the wiring check instead of a release. Not a verdict: what was
# done, why, and where the page is. PAGE_REF is how the page is referenced
# (a path on the check, a link in the comment).
wiring_line() {
  if [ "$(state_get wiring_why)" = "not_set_up" ]; then
    printf '%s' "Verging Labs has not activated the test suites on your agent setups yet, so this run performed the free wiring check instead of a release and committed its page ($1). Verging Labs tells you when your suites are set up; pushes after that run real releases."
  else
    printf '%s' "wiring_check is true, so this run performed the free wiring check instead of a release and committed its page ($1). Nothing was tested and nothing is billed."
  fi
}

# pending_line: the one line both surfaces say when this job stopped waiting
# before the report was ready. Not a verdict: the report follows later.
pending_line() {
  printf '%s' "Verging Labs is still testing release \`$release_id\` (last status: $(state_get last_status)). Your next push or the sync job commits the report when it is ready."
}

conclusion="neutral"
title="$verdict"
summary="Release \`$release_id\`. Report: \`$report_path\`."
case "$verdict" in
  Ready*) conclusion="success" ;;
esac
wiring="$(state_get wiring_done)"
pending=""
if [ "$wiring" = "1" ]; then
  # A wiring check is not a verdict: conclusion neutral (never a failure),
  # and the one line above in place of a verdict.
  title="Wiring check, not a release"
  summary="$(wiring_line "\`$report_path\`")"
elif [ "$verdict" = "Pending" ]; then
  # No report yet is not a verdict either: conclusion neutral, one line.
  pending="1"
  title="Report pending"
  summary="$(pending_line)"
fi

if [ -n "$repo" ] && [ -n "$head_sha" ]; then
  if gh api "repos/$repo/check-runs" -X POST \
      -f name="Verging Memory CI" \
      -f head_sha="$head_sha" \
      -f status="completed" \
      -f conclusion="$conclusion" \
      -f "output[title]=$title" \
      -f "output[summary]=$summary" \
      >/dev/null 2>&1; then
    echo "Posted the Verging Memory CI check on $head_sha (conclusion: $conclusion)."
  else
    echo "::warning::could not post the check run; the committed report is unaffected."
  fi
else
  echo "::warning::missing repository or commit context; skipping the check run."
fi

if [ "$event" = "pull_request" ] && [ -n "$pr_number" ] && [ -n "$repo" ]; then
  branch="$(state_get pushed_ref)"
  [ -n "$branch" ] || branch="${GITHUB_HEAD_REF:-main}"
  encoded_path="$(printf '%s' "$report_path" | sed 's/ /%20/g')"
  link="/$repo/blob/$branch/$encoded_path"
  # blob_link PATH LABEL: an HTML anchor to the committed file that opens in a
  # new tab (target="_blank": a plain markdown link would navigate the pull
  # request tab away from the review). Spaces are the one report-folder path
  # character a URL cannot carry raw.
  server_url="${GITHUB_SERVER_URL:-https://github.com}"
  blob_link() {
    printf '<a href="%s/%s/blob/%s/%s" target="_blank">%s</a>' \
      "$server_url" "$repo" "$branch" "$(printf '%s' "$1" | sed 's/ /%20/g')" "$2"
  }
  if [ "$wiring" = "1" ]; then
    body="<!-- verging-memory-ci -->
**Verging Memory CI: wiring check, not a release.** $(wiring_line "[read it]($link)")"
  elif [ "$pending" = "1" ]; then
    body="<!-- verging-memory-ci -->
**Verging Memory CI: report pending.** $(pending_line)"
  else
    # The report summary comment: the committed REPORT.md's own "Results at a
    # glance" section inline (the verdict's figures, readable without leaving
    # the pull request), then the committed files, each opening in a new tab.
    # One comment per pull request: a rerun updates the marker-bearing comment
    # in place below instead of stacking a second one.
    release_dir="${report_path%/REPORT.md}"
    glance="$(awk '/^## Results at a glance$/{on=1; next} on && /^## /{exit} on{print}' "$report_path" 2>/dev/null)"
    files="$(blob_link "$report_path" "Full report")"
    [ -f "$release_dir/diff.json" ] && files="$files | $(blob_link "$release_dir/diff.json" "diff.json")"
    index_path="$(dirname "$release_dir")/index.md"
    [ -f "$index_path" ] && files="$files | $(blob_link "$index_path" "All releases")"
    if [ -n "$glance" ]; then
      body="<!-- verging-memory-ci -->
**Verging Memory CI: $verdict**

Release \`$release_id\`.

### Results at a glance
$glance

$files"
    else
      # The committed report (or its glance section) is not readable here; the
      # comment still says what happened and where the report is.
      body="<!-- verging-memory-ci -->
**Verging Memory CI: $verdict**

Release \`$release_id\`. $files"
    fi
  fi
  existing="$(gh api "repos/$repo/issues/$pr_number/comments" --paginate \
    --jq '.[] | select(.body | startswith("<!-- verging-memory-ci -->")) | .id' 2>/dev/null \
    | head -n 1 || true)"
  if [ -n "$existing" ]; then
    if gh api "repos/$repo/issues/comments/$existing" -X PATCH -f body="$body" >/dev/null 2>&1; then
      echo "Updated the existing Verging Memory CI comment on pull request #$pr_number."
    else
      echo "::warning::could not update the pull request comment; the committed report is unaffected."
    fi
  else
    if gh api "repos/$repo/issues/$pr_number/comments" -X POST -f body="$body" >/dev/null 2>&1; then
      echo "Posted the Verging Memory CI comment on pull request #$pr_number."
    else
      echo "::warning::could not post the pull request comment; the committed report is unaffected."
    fi
  fi
fi
exit 0
