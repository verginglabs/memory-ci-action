#!/usr/bin/env bash
# Shared helpers for the Verging Memory CI action scripts.
#
# State that has to travel between the action's steps lives in plain files
# under $RUNNER_TEMP/verging-memory-ci-state. The API key is never written
# there; it stays in the environment of the steps that call the API.

state_dir() {
  local d="${RUNNER_TEMP:?RUNNER_TEMP is not set}/verging-memory-ci-state"
  mkdir -p "$d"
  printf '%s' "$d"
}

state_set() {
  printf '%s' "$2" > "$(state_dir)/$1"
}

state_get() {
  local f
  f="$(state_dir)/$1"
  if [ -f "$f" ]; then cat "$f"; else printf ''; fi
}

# api_get PATH OUTFILE: GET an API path, write the body to OUTFILE, print the
# HTTP status code ("000" when the request itself failed).
api_get() {
  local path="$1" out="$2" code
  code="$(curl -sS -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer ${VERGING_API_KEY:?VERGING_API_KEY is not set}" \
    "$(state_get api_base)$path")" || code="000"
  printf '%s' "$code"
}

# print_error_body FILE: print the error and fix lines of an API error body.
print_error_body() {
  if jq -e . "$1" >/dev/null 2>&1; then
    jq -r '"  error: \(.error // "-")\n  fix:   \(.fix // "-")"' "$1" || true
  else
    cat "$1" 2>/dev/null || true
  fi
}

git_config_identity() {
  if [ -z "$(git config user.name 2>/dev/null || true)" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
}

# write_release_dir REPORT_JSON DIR: write REPORT.md, diff.json, release.json,
# and evidence/ into DIR from a fetched report body.
write_release_dir() {
  local report="$1" dir="$2" count row name
  mkdir -p "$dir"

  # REPORT.md: the markdown the API returns.
  jq -r '.report_markdown // empty' "$report" > "$dir/REPORT.md"
  if [ ! -s "$dir/REPORT.md" ]; then
    echo "::error::the report body has no report_markdown"
    jq 'del(.diff)' "$report" || true
    return 1
  fi

  # diff.json: the machine-readable report, when present.
  if jq -e '.diff != null' "$report" >/dev/null; then
    jq '.diff' "$report" > "$dir/diff.json"
  else
    echo "::warning::the report body has no diff; diff.json not written"
  fi

  # release.json: the four fields the integration guide names.
  jq '{release_id, vendor_version, scope, corrections_due_by}' "$report" > "$dir/release.json"

  # evidence/: the files the report's Evidence pointers name, one per failed
  # test per release; nothing to write when every test passed. Only names of
  # the exact form evidence/<file>.md are written, so nothing can land
  # outside the release directory.
  rm -rf "$dir/evidence"
  count="$(jq -r '.evidence | length' "$report" 2>/dev/null || echo 0)"
  case "$count" in ''|null|*[!0-9]*) count=0 ;; esac
  if [ "$count" -gt 0 ]; then
    mkdir -p "$dir/evidence"
    jq -c '.evidence[]' "$report" | while IFS= read -r row; do
      name="$(printf '%s' "$row" | jq -r '.name')"
      if ! printf '%s' "$name" | grep -Eq '^evidence/[A-Za-z0-9][A-Za-z0-9._+-]*\.md$'; then
        echo "::warning::skipping evidence entry with unexpected name: $name"
        continue
      fi
      case "$name" in
        *..*) echo "::warning::skipping evidence entry with unexpected name: $name"; continue ;;
      esac
      printf '%s' "$row" | jq -r '.content' > "$dir/$name"
    done
    echo "Wrote $count evidence file(s) under $dir/evidence/"
  fi
  return 0
}

# extract_verdict REPORT_JSON REPORT_MD: the Release verdict, from the header
# table row in the markdown, else from diff.release_verdict.
extract_verdict() {
  local report="$1" md="$2" verdict_row verdict
  verdict_row="$(grep -m1 'Release verdict' "$md" || true)"
  verdict="$(printf '%s' "$verdict_row" \
    | sed -E 's/\*\*//g; s/^[[:space:]]*\|?[[:space:]]*Release verdict[[:space:]]*[|:]?[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*$//; s/[[:space:]]+$//')"
  if [ -z "$verdict" ]; then
    verdict="$(jq -r '.diff.release_verdict // "not recorded"' "$report")"
  fi
  printf '%s' "$verdict"
}

# slug_for RELEASE_DATE VENDOR_VERSION RELEASE_ID FOLDER: the release
# directory name. Folders are named by the release (its date and version),
# not by the internal id; the id lives in release.json and the index. A
# same-day resubmission of the same version gets the id's short stem appended.
slug_for() {
  local slug="$1-$2" dir="$4/releases/$1-$2"
  if [ -d "$dir" ] && [ "$(jq -r '.release_id // empty' "$dir/release.json" 2>/dev/null)" != "$3" ]; then
    slug="$slug-$(printf '%s' "$3" | tail -c 12)"
  fi
  printf '%s' "$slug"
}

ensure_index() {
  local index="$1/releases/index.md"
  mkdir -p "$1/releases"
  if [ ! -f "$index" ]; then
    {
      echo "# Releases"
      echo
      echo "One line per release, oldest first. Each release id links to its report."
      echo
      echo "| Date (UTC) | vendor_version | Release id | Release verdict | Stage |"
      echo "|---|---|---|---|---|"
    } > "$index"
  fi
}

# index_update_row FOLDER RELEASE_ID NEW_ROW: replace the index line that
# carries RELEASE_ID with NEW_ROW. No-op with a warning when the row or the
# index is missing.
index_update_row() {
  local index="$1/releases/index.md" id="$2" new_row="$3" line tmp
  if [ ! -f "$index" ]; then
    echo "::warning::$index does not exist; cannot update the row for $id"
    return 0
  fi
  line="$(grep -nF "[$id](" "$index" | head -n 1 | cut -d: -f1)"
  if [ -z "$line" ]; then
    echo "::warning::no index row found for $id; appending one instead"
    printf '%s\n' "$new_row" >> "$index"
    return 0
  fi
  tmp="$(state_dir)/index.tmp"
  {
    head -n "$((line - 1))" "$index"
    printf '%s\n' "$new_row"
    tail -n "+$((line + 1))" "$index"
  } > "$tmp"
  mv "$tmp" "$index"
}

# refresh_latest FOLDER DIR: latest/ is a plain copy of the newest release
# directory (copied, not symlinked, so it survives every checkout).
refresh_latest() {
  rm -rf "$1/latest"
  mkdir -p "$1/latest"
  cp -R "$2"/. "$1/latest/"
}

# ensure_folder_readme FOLDER: the folder README is written once, never
# overwritten.
ensure_folder_readme() {
  if [ ! -f "$1/README.md" ]; then
    cp "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/folder-readme.md" "$1/README.md"
  fi
}

# poll_release RELEASE_ID TIMEOUT_MINUTES: poll the status until the report
# is ready. Returns 0 on report_ready or corrected, 1 on failed or timeout.
poll_release() {
  local id="$1" timeout_min="$2" interval="${POLL_INTERVAL_SECONDS:-30}"
  local status_file deadline status code failure
  status_file="$(state_dir)/status.json"
  deadline=$(( $(date +%s) + timeout_min * 60 ))
  status="unknown"
  echo "Polling $(state_get api_base)/v1/releases/$id every ${interval}s for up to ${timeout_min} minutes"
  while :; do
    code="$(api_get "/v1/releases/$id" "$status_file")"
    if [ "$code" = "200" ]; then
      status="$(jq -r '.status // "unknown"' "$status_file")"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  status=$status  updated_at=$(jq -r '.updated_at // "-"' "$status_file")"
      case "$status" in
        report_ready|corrected)
          state_set status "$status"
          return 0
          ;;
        failed)
          failure="$(jq -r '.failure // "(no failure field on the status body)"' "$status_file")"
          echo "::error::release $id failed on the Verging side: $failure"
          echo "The release is voided; voided tests are never billed. Start a new release, or send Verging the release_id."
          {
            echo "**Release failed.** \`$id\`"
            echo
            echo "failure: $failure"
          } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
          return 1
          ;;
        held)
          echo "  held: $(jq -r '.message // "the environment is being set up on the Verging side; the release starts on its own"' "$status_file")"
          ;;
        queued|claimed|running)
          ;;
        *)
          echo "::warning::unexpected status '$status'; continuing to poll"
          ;;
      esac
    else
      echo "::warning::GET /v1/releases/$id returned HTTP $code; retrying"
      print_error_body "$status_file"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "::error::release $id is not report_ready after ${timeout_min} minutes (last status: $status). This job stops polling; the release may still finish on the Verging side. Do not start another release for the same version; send Verging the release_id, or re-run this workflow with fetch_only_release_id=$id once the report is ready, to fetch and commit it without submitting again."
      {
        echo "**Timed out waiting for the report.** \`$id\` last status: \`$status\`"
      } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
      return 1
    fi
    sleep "$interval"
  done
}

# fetch_and_write RELEASE_ID RELEASE_DATE: fetch the report and write the
# release directory, latest/, the index row, and the folder README. Records
# vendor_version, verdict, slug, and report_path in the step state.
fetch_and_write() {
  local id="$1" release_date="$2"
  local folder report code vendor_version slug dir verdict stage rstatus due
  folder="$(state_get folder)"
  report="$(state_dir)/report.json"
  code="$(api_get "/v1/releases/$id/report" "$report")"
  if [ "$code" != "200" ]; then
    echo "::error::GET /v1/releases/$id/report returned HTTP $code"
    print_error_body "$report"
    return 1
  fi

  vendor_version="$(jq -r '.vendor_version // empty' "$report")"
  [ -n "$vendor_version" ] || vendor_version="$(state_get vendor_version)"
  [ -n "$vendor_version" ] || vendor_version="not-recorded"

  slug="$(slug_for "$release_date" "$vendor_version" "$id" "$folder")"
  dir="$folder/releases/$slug"
  write_release_dir "$report" "$dir" || return 1
  refresh_latest "$folder" "$dir"
  ensure_folder_readme "$folder"

  verdict="$(extract_verdict "$report" "$dir/REPORT.md")"
  stage="$(jq -r '.diff.stage // "not recorded"' "$report")"
  rstatus="$(jq -r '.status // "not recorded"' "$report")"
  due="$(jq -r '.corrections_due_by // "-"' "$report")"
  echo "Release verdict: $verdict"
  echo "Stage: $stage   status: $rstatus   corrections_due_by: $due"

  ensure_index "$folder"
  if grep -qF "[$id](" "$folder/releases/index.md"; then
    index_update_row "$folder" "$id" \
      "| $release_date | $vendor_version | [$id]($slug/REPORT.md) | $verdict | $stage |"
  else
    printf '| %s | %s | [%s](%s/REPORT.md) | %s | %s |\n' \
      "$release_date" "$vendor_version" "$id" "$slug" "$verdict" "$stage" \
      >> "$folder/releases/index.md"
  fi

  state_set vendor_version "$vendor_version"
  state_set release_id "$id"
  state_set verdict "$verdict"
  state_set slug "$slug"
  state_set report_path "$folder/releases/$slug/REPORT.md"

  {
    echo "### Release verdict: $verdict"
    echo
    echo "Stage: \`$stage\`, status: \`$rstatus\`, corrections_due_by: $due"
    echo
    echo "Report: \`$dir/REPORT.md\` (copy in \`$folder/latest/REPORT.md\`)"
    echo
    echo "<details><summary>Top of the report</summary>"
    echo
    head -n 60 "$dir/REPORT.md"
    echo
    echo "</details>"
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  return 0
}

# push_with_fallback: push HEAD to the triggering branch with a fetch and
# rebase retry. If the push still fails, the job does NOT fail: the same
# commit is delivered on the branch verging-memory-ci/reports with a pull
# request into the default branch.
push_with_fallback() {
  local branch attempt default_branch existing
  branch="${GITHUB_HEAD_REF:-}"
  [ -n "$branch" ] || branch="${GITHUB_REF_NAME:-}"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || branch="main"

  for attempt in 1 2 3; do
    if git push origin "HEAD:$branch"; then
      echo "Report commit pushed to $branch."
      state_set pushed_ref "$branch"
      state_set push_path "direct"
      return 0
    fi
    echo "Push attempt $attempt to $branch failed; fetching and rebasing on origin/$branch."
    git fetch origin "$branch" || true
    git rebase "origin/$branch" || { git rebase --abort 2>/dev/null || true; }
  done

  echo "::warning::could not push the report commit to $branch after 3 attempts; delivering it on the branch verging-memory-ci/reports instead. The job does not fail on this."
  if ! git push --force origin "HEAD:refs/heads/verging-memory-ci/reports"; then
    echo "::warning::the push to verging-memory-ci/reports failed too. The report stays in this run's log; re-run with fetch_only_release_id=$(state_get release_id) once pushing works again, to fetch and commit it without submitting anything."
    state_set push_path "none"
    return 0
  fi
  state_set pushed_ref "verging-memory-ci/reports"
  state_set push_path "fallback"

  default_branch="${VERGING_DEFAULT_BRANCH:-}"
  if [ -z "$default_branch" ]; then
    default_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  fi
  [ -n "$default_branch" ] || default_branch="main"

  existing="$(gh pr list --head verging-memory-ci/reports --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "Direct push to $branch failed; the report commit is on verging-memory-ci/reports, and the open pull request #$existing into $default_branch now carries it."
  elif gh pr create --head verging-memory-ci/reports --base "$default_branch" \
      --title "Verging Memory CI reports" \
      --body "The direct push of the Verging Memory CI report commit to \`$branch\` did not go through (a protected branch or a race with other pushes can cause this). This branch carries the same commit. Merge it to keep the report folder current."; then
    echo "Direct push to $branch failed; the report commit is on verging-memory-ci/reports, and a pull request into $default_branch was opened for it."
  else
    echo "::warning::could not open the pull request from verging-memory-ci/reports into $default_branch; the branch itself carries the report commit."
  fi
  return 0
}
