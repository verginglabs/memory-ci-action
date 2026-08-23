#!/usr/bin/env bash
# Commit the report folder and push it to the triggering branch, with a
# fetch and rebase retry. A push that still fails never fails the job: the
# commit is delivered on the branch verging-memory-ci/reports with a pull
# request into the default branch (see push_with_fallback in lib.sh).
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ "$(state_get mode)" = "sync" ]; then
  echo "mode is sync; the sync step already committed what there was to commit."
  exit 0
fi

folder="$(state_get folder)"
vendor_version="$(state_get vendor_version)"
release_id="$(state_get release_id)"
verdict="$(state_get verdict)"

if [ -z "$release_id" ] || [ -z "$verdict" ]; then
  echo "No report was fetched this run; nothing to commit."
  exit 0
fi

git_config_identity
git add "$folder"
if git diff --cached --quiet; then
  echo "Nothing to commit; the report folder already carries this report."
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"
  state_set pushed_ref "$branch"
  state_set push_path "none-needed"
  exit 0
fi
git commit -m "Verging Memory CI: report for $vendor_version ($release_id): $verdict"
push_with_fallback
