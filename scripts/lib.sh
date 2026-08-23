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

# ---------------------------------------------------------------------------
# THE NAME RULES. One place, mirroring the API's lib/safe-name.mjs exactly,
# so the client and the API cannot drift apart on what a customer may type.
#
# The API routes two rules by field name (its SAFE_NAME_RE and SAFE_TITLE_RE):
#
#   slug rule, for vendor_version. Letters, digits, dots, underscores, plus
#   signs and hyphens; no leading hyphen; 1 to 64 characters. vendor_version
#   keeps this rule because it names the delivered evidence files, so it is a
#   path segment.
#
#   display-name rule, for product_name and the environment (agent setup)
#   name. The slug charset PLUS single internal spaces, so institutional
#   names like "Production MCP" and "Agent SDK" are accepted (ruled by
#   #472 D6 A). No leading or trailing space, no doubled space, still no
#   leading hyphen, still 1 to 64 characters.
#
# The environment name becomes a directory: the API lowercases it and turns
# spaces into hyphens to get the agent-setup slug that names the evidence
# subdirectory. agent_setup_slug is that same transform, and every slug is
# put through safe_path_segment_ok before it is trusted as a folder name.

# safe_name_ok NAME: the API's slug rule.
safe_name_ok() {
  local name="$1"
  [ "${#name}" -ge 1 ] && [ "${#name}" -le 64 ] || return 1
  case "$name" in -*) return 1 ;; esac
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._+-]+$'
}

# safe_title_ok NAME: the API's display-name rule.
safe_title_ok() {
  local name="$1"
  [ "${#name}" -ge 1 ] && [ "${#name}" -le 64 ] || return 1
  case "$name" in -*) return 1 ;; esac
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._+-]+( [A-Za-z0-9._+-]+)*$'
}

# agent_setup_slug NAME: the directory name the API derives from an
# agent-setup name, character for character with the report renderer's
# String(name).toLowerCase().replace(/ /g, "-").
agent_setup_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ' ' '-'
}

# safe_path_segment_ok SEGMENT: true when SEGMENT is safe to use as ONE
# directory or file name. This is the guard that keeps a widened name rule
# from widening what can be written: whatever a customer may type, the
# segment it produces still cannot be this directory, its parent, or a path.
#
# "." and ".." are refused even though the API's name rule accepts them as
# names: an agent setup named ".." would slug to ".." and name the parent
# directory. A dot INSIDE a segment ("a..b") is an ordinary character and is
# allowed, exactly as the API allows it.
safe_path_segment_ok() {
  local seg="$1"
  case "$seg" in
    ''|.|..) return 1 ;;
    -*) return 1 ;;
    */*) return 1 ;;
  esac
  printf '%s' "$seg" | grep -Eq '^[A-Za-z0-9._+-]+$'
}

# evidence_name_ok NAME: true when NAME is a name the Verging Memory CI API
# emits for an evidence file, and nothing else.
#
# THE EVIDENCE PATH CONTRACT (keep this in step with the report renderer):
#
#   evidence/<file>.md                     one agent setup on the release
#   evidence/<agent-setup>/<file>.md       a release across several setups
#
# <agent-setup> is agent_setup_slug of the setup name; <file> is
# <test-id>-<vendor_version>.md. Exactly one setup segment is accepted: no
# deeper nesting, no leading slash, no absolute path, ".md" only, and every
# segment goes through safe_path_segment_ok. So a written file can only land
# inside the release directory's evidence/ folder.
evidence_name_ok() {
  local name="$1" rest seg file
  case "$name" in
    evidence/*) rest="${name#evidence/}" ;;
    *) return 1 ;;
  esac
  case "$rest" in
    */*/*) return 1 ;;
    */*) seg="${rest%%/*}"; file="${rest#*/}"; [ -n "$seg" ] || return 1 ;;
    *) seg=""; file="$rest" ;;
  esac
  if [ -n "$seg" ]; then safe_path_segment_ok "$seg" || return 1; fi
  case "$file" in *.md) ;; *) return 1 ;; esac
  safe_path_segment_ok "$file"
}

# write_release_dir REPORT_JSON DIR: write REPORT.md, diff.json, release.json,
# and evidence/ into DIR from a fetched report body.
write_release_dir() {
  local report="$1" dir="$2" count row name written refused prior
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
  # test per release; nothing to write when every test passed. Every name is
  # checked against evidence_name_ok before anything is written, so a file
  # can only land inside this release's evidence/ directory.
  rm -rf "$dir/evidence"
  count="$(jq -r '.evidence | length' "$report" 2>/dev/null || echo 0)"
  case "$count" in ''|null|*[!0-9]*) count=0 ;; esac
  if [ "$count" -gt 0 ]; then
    mkdir -p "$dir/evidence"
    written=0
    refused=0
    while IFS= read -r row; do
      name="$(printf '%s' "$row" | jq -r '.name')"
      if ! evidence_name_ok "$name"; then
        echo "::error::refusing an evidence entry whose name is not one this action writes: $name"
        refused=$((refused + 1))
        continue
      fi
      mkdir -p "$(dirname "$dir/$name")"
      printf '%s' "$row" | jq -r '.content' > "$dir/$name"
      written=$((written + 1))
    done < <(jq -c '.evidence[]' "$report")
    echo "Wrote $written of $count evidence file(s) under $dir/evidence/"
    if [ "$refused" -gt 0 ]; then
      echo "::error::$refused of $count evidence file(s) were not written; the report links to files that are not in this folder"
      prior="$(state_get evidence_refused)"
      case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
      state_set evidence_refused "$((prior + refused))"
    fi
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

# apply_final_report REL_DIR REPORT_JSON: rewrite an existing release
# directory in place from a fetched FINAL report body (git history keeps the
# preliminary report), update the release's index row to stage final, and
# refresh latest/ when this release is the newest one on record. Sets
# APPLIED_ID, APPLIED_VERSION, APPLIED_VERDICT, APPLIED_PATH for the caller.
# Returns 1, with the directory possibly half rewritten, when the body
# cannot be written; the caller restores the directory.
apply_final_report() {
  local rel="$1" report="$2" folder id version slug release_date verdict
  folder="$(state_get folder)"
  id="$(jq -r '.release_id // empty' "$rel/release.json")"
  version="$(jq -r '.vendor_version // "not recorded"' "$rel/release.json")"
  write_release_dir "$report" "$rel" || return 1
  verdict="$(extract_verdict "$report" "$rel/REPORT.md")"

  slug="$(basename "$rel")"
  case "$slug" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      release_date="$(printf '%s' "$slug" | cut -c1-10)"
      ;;
    *)
      release_date="$(grep -F "[$id](" "$folder/releases/index.md" 2>/dev/null | head -n 1 \
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

  APPLIED_ID="$id"
  APPLIED_VERSION="$version"
  APPLIED_VERDICT="$verdict"
  APPLIED_PATH="$rel/REPORT.md"
  return 0
}

# sync_finals_pass POST_SURFACES: the finals sync. The repository is the
# source of what needs syncing: every release directory whose committed
# diff.json is stage "preliminary" is a release still awaiting its final
# report. Each one's status is asked for with the customer key; the ones
# whose status is "corrected" have their final report fetched and the
# release directory replaced in place, latest/ and the index updated exactly
# as the preliminary path does. One commit carries the whole pass, pushed
# with the same fallback the release path uses. A release in any other state
# is left alone, and a final report on disk is never replaced by anything.
#
# Runs on every job: first thing in release mode (an active customer gets
# every final report with zero extra configuration), and as the whole job in
# sync mode. With POST_SURFACES=1 (sync mode) it also posts one commit
# status per synced release on the sync commit, and writes the job summary.
sync_finals_pass() {
  local post_surfaces="${1:-0}"
  local folder releases_dir rel stage id version code status new_stage
  local status_file report awaiting synced message repo head_sha conclusion i
  folder="$(state_get folder)"
  releases_dir="$folder/releases"

  if [ ! -d "$releases_dir" ]; then
    echo "Nothing to sync ($releases_dir does not exist yet)."
    return 0
  fi
  if [ -f "$releases_dir/index.md" ]; then
    echo "Releases on record in $releases_dir/index.md:"
    grep -E '^\| [0-9]' "$releases_dir/index.md" || echo "  (none yet)"
  fi

  awaiting=0
  synced=0
  local -a synced_ids=() synced_versions=() synced_verdicts=() synced_paths=() synced_labels=()
  for rel in "$releases_dir"/*/; do
    rel="${rel%/}"
    [ -f "$rel/release.json" ] || continue
    [ -f "$rel/diff.json" ] || continue
    stage="$(jq -r '.stage // empty' "$rel/diff.json")"
    [ "$stage" = "preliminary" ] || continue
    id="$(jq -r '.release_id // empty' "$rel/release.json")"
    [ -n "$id" ] || continue
    version="$(jq -r '.vendor_version // "not recorded"' "$rel/release.json")"
    awaiting=$((awaiting + 1))
    echo "Release $id ($version) is on its preliminary report; asking whether the final report is out"

    status_file="$(state_dir)/sync-status.json"
    code="$(api_get "/v1/releases/$id" "$status_file")"
    if [ "$code" != "200" ]; then
      echo "::warning::GET /v1/releases/$id returned HTTP $code; leaving the preliminary report in place"
      print_error_body "$status_file"
      continue
    fi
    status="$(jq -r '.status // "unknown"' "$status_file")"
    if [ "$status" != "corrected" ]; then
      echo "The final report for $id ($version) is not out yet (status: $status); leaving the preliminary report in place."
      continue
    fi

    report="$(state_dir)/sync-report.json"
    code="$(api_get "/v1/releases/$id/report" "$report")"
    if [ "$code" != "200" ]; then
      echo "::warning::GET /v1/releases/$id/report returned HTTP $code; leaving the preliminary report in place"
      print_error_body "$report"
      continue
    fi
    new_stage="$(jq -r '.diff.stage // empty' "$report")"
    if [ "$new_stage" != "final" ]; then
      echo "::warning::release $id reads corrected but the fetched report is not the final report (stage: ${new_stage:-not recorded}); leaving the preliminary report in place"
      continue
    fi

    if ! apply_final_report "$rel" "$report"; then
      echo "::warning::could not rewrite $rel from the fetched final report; leaving it as it was"
      git checkout -- "$rel" 2>/dev/null || true
      git clean -qfd -- "$rel" 2>/dev/null || true
      continue
    fi
    echo "Final report for $APPLIED_VERSION ($APPLIED_ID): $APPLIED_VERDICT"
    synced=$((synced + 1))
    synced_ids+=("$APPLIED_ID")
    synced_versions+=("$APPLIED_VERSION")
    synced_verdicts+=("$APPLIED_VERDICT")
    synced_paths+=("$APPLIED_PATH")
    synced_labels+=("$APPLIED_VERSION ($APPLIED_ID)")
    state_set release_id "$APPLIED_ID"
    state_set vendor_version "$APPLIED_VERSION"
    state_set verdict "$APPLIED_VERDICT"
    state_set report_path "$APPLIED_PATH"
  done

  if [ "$synced" -eq 0 ]; then
    if [ "$awaiting" -eq 0 ]; then
      echo "Nothing to sync; every report on record is already final."
    else
      echo "Nothing to commit; $awaiting release(s) still await their final report."
    fi
    return 0
  fi

  git_config_identity
  git add "$folder"
  if git diff --cached --quiet; then
    echo "Nothing to commit; the folder already carries these final reports."
    return 0
  fi
  if [ "$synced" -eq 1 ]; then
    message="Verging Memory CI: final report for ${synced_labels[0]}"
  else
    message="Verging Memory CI: final reports for $(printf '%s, ' "${synced_labels[@]}" | sed 's/, $//')"
  fi
  git commit -m "$message"
  echo "Committed: $message"
  push_with_fallback

  if [ "$post_surfaces" = "1" ]; then
    repo="${GITHUB_REPOSITORY:-}"
    head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    i=0
    while [ "$i" -lt "$synced" ]; do
      conclusion="neutral"
      case "${synced_verdicts[$i]}" in Ready*) conclusion="success" ;; esac
      if [ -n "$repo" ] && [ -n "$head_sha" ]; then
        if gh api "repos/$repo/check-runs" -X POST \
            -f name="Verging Memory CI" \
            -f head_sha="$head_sha" \
            -f status="completed" \
            -f conclusion="$conclusion" \
            -f "output[title]=final report for ${synced_versions[$i]}" \
            -f "output[summary]=Release \`${synced_ids[$i]}\`. Report: \`${synced_paths[$i]}\`." \
            >/dev/null 2>&1; then
          echo "Posted the commit status for the final report for ${synced_versions[$i]} (conclusion: $conclusion)."
        else
          echo "::warning::could not post the commit status for ${synced_labels[$i]}; the committed report is unaffected."
        fi
      else
        echo "::warning::missing repository or commit context; skipping the commit status for ${synced_labels[$i]}."
      fi
      {
        echo "### Final report for ${synced_versions[$i]}: ${synced_verdicts[$i]}"
        echo
        echo "Release \`${synced_ids[$i]}\`. Report: \`${synced_paths[$i]}\`"
        echo
      } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
      i=$((i + 1))
    done
  fi
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
