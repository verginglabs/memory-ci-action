#!/usr/bin/env bash
# Reconcile pass, run at the start of every run before anything is
# submitted: every release in the folder that is still on its preliminary
# report is re-fetched, and where the final report is out, the release
# directory is rewritten, latest/ is refreshed when that release is the
# newest, and the change is committed and pushed. Reports are never lost to
# a run that happened before the final report was out.
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

  git_config_identity
  git add "$folder"
  if ! git diff --cached --quiet; then
    git commit -m "Verging Memory CI: final report for $version ($id)"
    committed=1
    echo "Committed the final report for $version ($id): $verdict"
  fi
done

if [ "$committed" = "1" ]; then
  push_with_fallback
elif [ "$checked" = "0" ]; then
  echo "Nothing to reconcile; every report on record is already final."
fi
