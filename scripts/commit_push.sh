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

# take_committed_report BRANCH DIR: the branch already carries this release's
# report at DIR (an earlier attempt of this workflow run committed it: the
# Idempotency-Key gave the re-run the same release, and the re-run's checkout
# is the commit before that report commit, so the report was written here
# again). The copy written here is set aside, the checkout is moved up to
# the branch, and:
#   - when the copy is the same report, nothing is committed or pushed: the
#     run ends with the outputs a fresh run has (true);
#   - when it differs (the final or a corrected report came out since), the
#     copy is laid over the branch's directory as an update, its index row
#     and latest/ with it, and the normal commit follows (false);
#   - when the checkout cannot be moved up (it has diverged from the branch,
#     as a pull request's merge checkout has), the copy is put back and the
#     normal commit follows; the push loop's rebase then takes the branch's
#     version of the same report (false).
take_committed_report() {
  local branch="$1" dir="$2" aside mine own_row v
  aside="$(state_dir)/written-folder"
  rm -rf "$aside"
  mkdir -p "$aside"
  cp -R "$folder"/. "$aside/"
  git checkout -q -- "$folder" 2>/dev/null || true
  git clean -fdq -- "$folder"
  state_set pushed_ref "$branch"
  if ! git merge -q --ff-only "origin/$branch" >/dev/null 2>&1; then
    echo "origin/$branch carries the report for release $release_id at $dir, but the checkout cannot be moved up to it (they have diverged); this run's copy is committed and the push rebases it on the branch."
    mkdir -p "$folder"
    cp -R "$aside/." "$folder/"
    return 1
  fi
  echo "The checkout is moved up to origin/$branch, which carries the report for release $release_id at $dir."
  mine="$aside/${dir#"$folder/"}"
  if [ ! -d "$mine" ] || diff -rq "$mine" "$dir" >/dev/null 2>&1; then
    echo "This release's report is already committed by an earlier attempt of this workflow run; nothing to push."
    state_set push_path "already-committed"
    state_set report_path "$dir/REPORT.md"
    state_set slug "$(basename "$dir")"
    if [ "$verdict" = "Pending" ]; then
      # This run stopped waiting, but the report is in: the outputs say so.
      v="$(verdict_row_of "$dir/REPORT.md")"
      [ -n "$v" ] && state_set verdict "$v"
    fi
    {
      echo "The report for release \`$release_id\` is already committed on \`$branch\` by an earlier attempt of this workflow run (\`$dir/REPORT.md\`); nothing to push."
      echo
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    return 0
  fi
  echo "The report this run fetched for release $release_id differs from the copy on origin/$branch (the final or a corrected report); it is committed over that copy as an update."
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$mine/." "$dir/"
  refresh_latest "$folder" "$dir"
  own_row="$(grep -F -e "[$release_id](" -e "| $release_id |" "$aside/releases/index.md" 2>/dev/null | head -n 1 || true)"
  [ -n "$own_row" ] && index_put_row "$folder" "$release_id" "$own_row"
  pending_clear "$folder" "$release_id"
  state_set report_path "$dir/REPORT.md"
  state_set slug "$(basename "$dir")"
  return 1
}

# The branch is asked first whether it already carries this release's report
# (a re-run of a workflow run whose earlier attempt committed it). A wiring
# page is found the same way, by the release id in its release.json.
if [ -n "$folder" ] && [ -n "$release_id" ]; then
  branch="$(report_branch)"
  if fetch_branch "$branch"; then
    remote_dir="$(remote_report_dir "$folder" "$release_id" "$branch")"
    if [ -n "$remote_dir" ] && [ "$remote_dir" != "index" ]; then
      if take_committed_report "$branch" "$remote_dir"; then
        exit 0
      fi
    fi
  else
    echo "origin/$branch could not be fetched; committing without asking the branch for an earlier attempt's report."
  fi
fi

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
