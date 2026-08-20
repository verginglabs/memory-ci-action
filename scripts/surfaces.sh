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

conclusion="neutral"
case "$verdict" in
  Ready*) conclusion="success" ;;
esac

if [ -n "$repo" ] && [ -n "$head_sha" ]; then
  if gh api "repos/$repo/check-runs" -X POST \
      -f name="Verging Memory CI" \
      -f head_sha="$head_sha" \
      -f status="completed" \
      -f conclusion="$conclusion" \
      -f "output[title]=$verdict" \
      -f "output[summary]=Release \`$release_id\`. Report: \`$report_path\`." \
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
  body="<!-- verging-memory-ci -->
**Verging Memory CI: $verdict**

Release \`$release_id\`. [Read the report]($link)."
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
