#!/usr/bin/env bash
# Reconcile pass, run at the start of every job (release and sync alike)
# before anything is submitted. Two kinds of report land after the job that
# submitted the release, and both are collected here:
#
#   1. The report of a release on record as pending (releases/pending.json):
#      a job stopped waiting before the report was ready. When the release is
#      report_ready or corrected, its report is fetched and written exactly
#      as a fresh delivery would be (release directory, index row, latest/)
#      and the entry is cleared. When the release failed on the Verging side,
#      the failure goes on its index row and the entry is cleared; the job
#      stays green. Otherwise the release stays on record as pending.
#   2. The final report of a release still on its preliminary report: the
#      release directory is rewritten, latest/ is refreshed when that release
#      is the newest, and the index row says final.
#
# Every change is committed and pushed from here, so a report is never lost
# to a job that happened before it was out. A refused push fails the job with
# the named error of push_report_commit (lib.sh); the pending record and the
# preliminary report stay on the branch, so the next job collects again.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

folder="$(state_get folder)"
releases_dir="$folder/releases"

if [ ! -d "$releases_dir" ]; then
  echo "No earlier reports to reconcile ($releases_dir does not exist yet)."
  exit 0
fi
if [ -f "$releases_dir/index.md" ]; then
  echo "Releases on record in $releases_dir/index.md:"
  grep -E '^\| [0-9]' "$releases_dir/index.md" || echo "  (none yet)"
fi

committed=0
checked=0

# commit_folder MESSAGE: commit whatever changed in the folder; true when a
# commit was made.
commit_folder() {
  git_config_identity
  git add -A -- "$folder"
  if git diff --cached --quiet; then
    return 1
  fi
  git commit -m "$1"
  committed=1
  return 0
}

# ---- 1. releases on record as pending --------------------------------------
pending="$(pending_path "$folder")"
if [ -f "$pending" ] && ! jq -e 'type == "object"' "$pending" >/dev/null 2>&1; then
  echo "::warning::$pending is not a JSON object; leaving it alone"
fi
for id in $(pending_ids "$folder"); do
  entry="$(pending_get "$folder" "$id")"
  version="$(printf '%s' "$entry" | jq -r '.vendor_version // "not-recorded"')"
  submitted_at="$(printf '%s' "$entry" | jq -r '.submitted_at // empty')"
  last="$(printf '%s' "$entry" | jq -r '.status // "unknown"')"
  checked=$((checked + 1))
  echo "Release $id ($version) is on record as pending since ${submitted_at:-an unrecorded time} (last status: $last); asking for its status"

  status_file="$(state_dir)/reconcile-status.json"
  code="$(api_get "/v1/releases/$id" "$status_file")"
  if [ "$code" != "200" ]; then
    echo "::warning::GET /v1/releases/$id returned HTTP $code; leaving the release on record as pending"
    print_error_body "$status_file"
    continue
  fi
  status="$(jq -r '.status // "unknown"' "$status_file")"
  release_date="$(printf '%s' "$submitted_at" | cut -c1-10)"
  [ -n "$release_date" ] || release_date="$(jq -r '.received_at // empty' "$status_file" | cut -c1-10)"
  [ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"

  case "$status" in
    report_ready|corrected)
      echo "The report for $id is ready (status: $status); fetching it."
      # latest/ stays with a newer release whose report is already on record.
      latest_mode=""
      newest="$(index_newest_date "$folder")"
      if [ -n "$newest" ] && [ "$release_date" \< "$newest" ]; then
        latest_mode="keep-latest"
      fi
      # fetch_and_write records the fetched release in the step state. This
      # job's own release, resolved before this pass, must not be replaced by
      # it, so the state is put back afterwards.
      saved_version="$(state_get vendor_version)"
      saved_id="$(state_get release_id)"
      saved_verdict="$(state_get verdict)"
      saved_slug="$(state_get slug)"
      saved_path="$(state_get report_path)"
      state_set vendor_version "$version"
      written=0
      if fetch_and_write "$id" "$release_date" $latest_mode; then
        written=1
        verdict="$(state_get verdict)"
      fi
      state_set vendor_version "$saved_version"
      state_set release_id "$saved_id"
      state_set verdict "$saved_verdict"
      state_set slug "$saved_slug"
      state_set report_path "$saved_path"
      if [ "$written" != "1" ]; then
        echo "::warning::could not write the report for $id; leaving the release on record as pending"
        git checkout -- "$folder" 2>/dev/null || true
        git clean -fdq -e pending.json -- "$releases_dir" "$folder/latest" 2>/dev/null || true
        continue
      fi
      if commit_folder "Verging Memory CI: report for $version ($id): $verdict"; then
        echo "Committed the report for $version ($id): $verdict. The release is no longer pending."
      fi
      ;;
    failed)
      failure="$(jq -r '.failure // "(no failure field on the status body)"' "$status_file")"
      echo "::warning::release $id ($version) failed on the Verging side: $failure. The release is voided; voided tests are never billed. Start a new release, or send the release_id to contact@verginglabs.com."
      row_failure="$(printf '%s' "$failure" | tr '\n|' ' /')"
      index_put_row "$folder" "$id" "| $release_date | $version | $id | Failed: $row_failure | failed |"
      pending_clear "$folder" "$id"
      ensure_folder_readme "$folder"
      {
        echo "**Release \`$id\` ($version) failed on the Verging side.** $failure"
        echo
        echo "The failure is on its row in \`$releases_dir/index.md\`; the release is no longer pending. The release is voided; voided tests are never billed."
        echo
      } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
      if commit_folder "Verging Memory CI: release $version ($id) failed on the Verging side"; then
        echo "Recorded the failure of $version ($id) in the index. The release is no longer pending."
      fi
      ;;
    *)
      echo "Release $id ($version) is still being tested (status: $status); leaving it on record as pending."
      ;;
  esac
done

# ---- 2. preliminary reports whose final report is out ----------------------
for rel in "$releases_dir"/*/; do
  rel="${rel%/}"
  [ -f "$rel/release.json" ] || continue
  [ -f "$rel/diff.json" ] || continue
  stage="$(jq -r '.stage // empty' "$rel/diff.json")"
  [ "$stage" = "preliminary" ] || continue
  id="$(jq -r '.release_id // empty' "$rel/release.json")"
  [ -n "$id" ] || continue
  version="$(jq -r '.vendor_version // "not recorded"' "$rel/release.json")"
  checked=$((checked + 1))
  echo "Release $id ($version) is on its preliminary report; asking whether the final report is out"

  report="$(state_dir)/reconcile-report.json"
  code="$(api_get "/v1/releases/$id/report" "$report")"
  if [ "$code" != "200" ]; then
    echo "::warning::GET /v1/releases/$id/report returned HTTP $code; leaving the preliminary report in place"
    print_error_body "$report"
    continue
  fi
  new_stage="$(jq -r '.diff.stage // empty' "$report")"
  if [ "$new_stage" != "final" ]; then
    echo "The final report for $id is not out yet (stage: ${new_stage:-not recorded}); leaving the preliminary report in place."
    continue
  fi

  if ! write_release_dir "$report" "$rel"; then
    echo "::warning::could not rewrite $rel from the fetched final report; leaving it as it was"
    git checkout -- "$rel" 2>/dev/null || true
    continue
  fi
  verdict="$(extract_verdict "$report" "$rel/REPORT.md")"

  slug="$(basename "$rel")"
  case "$slug" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      release_date="$(printf '%s' "$slug" | cut -c1-10)"
      ;;
    *)
      release_date="$(grep -F "[$id](" "$releases_dir/index.md" 2>/dev/null | head -n 1 \
        | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')"
      ;;
  esac
  [ -n "$release_date" ] || release_date="$(date -u +%Y-%m-%d)"
  index_update_row "$folder" "$id" \
    "| $release_date | $version | [$id]($slug/REPORT.md) | $verdict | final |"

  # latest/ is refreshed only when this release is the newest one on record.
  if [ "$(jq -r '.release_id // empty' "$folder/latest/release.json" 2>/dev/null)" = "$id" ]; then
    refresh_latest "$folder" "$rel"
  fi

  if commit_folder "Verging Memory CI: final report for $version ($id)"; then
    echo "Committed the final report for $version ($id): $verdict"
  fi
done

if [ "$committed" = "1" ]; then
  push_report_commit
elif [ "$checked" = "0" ]; then
  echo "Nothing to reconcile; no release is pending and every report on record is already final."
fi
