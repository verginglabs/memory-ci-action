#!/usr/bin/env bash
# Commit the report folder and push it to the branch this job ran on, with a
# fetch and rebase retry. A push that is still refused FAILS the job with a
# named error saying what to allow; no other branch is written and no pull
# request is opened unless the fallback_pull_request input is on (see
# push_report_commit in lib.sh).
#
# This step runs whenever the job was not cancelled, so a release the job
# stopped waiting for is committed as pending (releases/pending.json), and so
# is one whose report could not be fetched after the receipt: the reconcile
# pass of the next job, or of a sync job, collects the report from the record.
#
# Every commit message here carries [skip ci] (2026-08-31): GitHub Actions
# honors it, so the push of a report commit can never start another workflow
# job on the customer's repository and loop. Customers on another CI system
# are told in the integration guide to exclude the report folder's path from
# their triggers.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

folder="$(state_get folder)"
vendor_version="$(state_get vendor_version)"
release_id="$(state_get release_id)"
verdict="$(state_get verdict)"

# pending_version: the vendor_version on the pending entry, for a job that
# resolved none of its own (fetch_only_release_id).
pending_version() {
  pending_get "$folder" "$release_id" | jq -r '.vendor_version // "not-recorded"'
}

if [ -z "$release_id" ] || [ -z "$verdict" ]; then
  # No report and no pending stop this job. The one thing that can still be
  # uncommitted is a pending entry written after a receipt by a step that
  # then failed: only that file is committed, never a half-written release
  # directory.
  if [ -n "$folder" ] && [ -n "$release_id" ] && [ -f "$(pending_path "$folder")" ]; then
    git_config_identity
    git add -- "$(pending_path "$folder")"
    if ! git diff --cached --quiet; then
      [ -n "$vendor_version" ] || vendor_version="$(pending_version)"
      git commit -m "Verging Memory CI: release $vendor_version ($release_id) is pending; the report follows [skip ci]"
      echo "The report was not fetched this run; the release is committed as pending, and the next job collects its report."
      push_report_commit || exit 1
      exit 0
    fi
  fi
  echo "No report was fetched this run; nothing to commit."
  exit 0
fi

git_config_identity
git add -A -- "$folder"
if git diff --cached --quiet; then
  echo "Nothing to commit; the report folder already carries this report."
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"
  state_set pushed_ref "$branch"
  state_set push_path "none-needed"
  exit 0
fi
if [ "$(state_get wiring_done)" = "1" ]; then
  # A wiring check's page: committed like a report, named for what it is.
  git commit -m "Verging Memory CI: wiring check for $vendor_version ($release_id) [skip ci]"
elif [ "$verdict" = "Pending" ]; then
  # The job stopped waiting: the pending record, so a later job collects the
  # report.
  [ -n "$vendor_version" ] || vendor_version="$(pending_version)"
  git commit -m "Verging Memory CI: release $vendor_version ($release_id) is pending; the report follows [skip ci]"
else
  git commit -m "Verging Memory CI: report for $vendor_version ($release_id): $verdict [skip ci]"
fi
push_report_commit
