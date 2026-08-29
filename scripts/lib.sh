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
#   names like "Claude Code Opus 5" and "Hermes GPT-5.6 Luna" are accepted (ruled by
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
      echo "One line per release, oldest first. Each release id links to its report; a release that failed on the Verging side has no report and says so."
      echo
      echo "| Date (UTC) | vendor_version | Release id | Release verdict | Stage |"
      echo "|---|---|---|---|---|"
    } > "$index"
  fi
}

# index_row_line INDEX RELEASE_ID: the line number of the row that carries
# RELEASE_ID (linked to its report, or bare on a row without one), or empty.
index_row_line() {
  [ -f "$1" ] || return 0
  { grep -nF -e "[$2](" -e "| $2 |" "$1" || true; } | head -n 1 | cut -d: -f1
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
  line="$(index_row_line "$index" "$id")"
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

# index_put_row FOLDER RELEASE_ID ROW: the one way a row reaches the index.
# A row already carrying RELEASE_ID is replaced in place; otherwise ROW goes
# in date order, before the first row dated later than it, so a report that
# lands after a newer release's (a release a job stopped waiting for, or one
# fetched by hand) keeps the index oldest first.
index_put_row() {
  local folder="$1" id="$2" row="$3" index tmp date
  index="$folder/releases/index.md"
  ensure_index "$folder"
  if [ -n "$(index_row_line "$index" "$id")" ]; then
    index_update_row "$folder" "$id" "$row"
    return 0
  fi
  date="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')"
  tmp="$(state_dir)/index.tmp"
  ROW="$row" DATE="$date" awk '
    BEGIN { done = 0 }
    !done && /^\| [0-9]/ {
      split($0, c, "|"); d = c[2]; gsub(/^ +| +$/, "", d)
      if (d > ENVIRON["DATE"]) { print ENVIRON["ROW"]; done = 1 }
    }
    { print }
    END { if (!done) print ENVIRON["ROW"] }
  ' "$index" > "$tmp" && mv "$tmp" "$index"
}

# index_newest_date FOLDER: the latest date on any index row, or empty.
index_newest_date() {
  [ -f "$1/releases/index.md" ] || return 0
  { grep -E '^\| [0-9]{4}-' "$1/releases/index.md" || true; } \
    | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}' | sort | tail -n 1
}

# ---------------------------------------------------------------------------
# THE PENDING RECORD: <folder>/releases/pending.json, one JSON object keyed
# by release id, one entry per release whose report has not reached the
# folder yet:
#
#   {"<release_id>": {"vendor_version": "2.31.0",
#                     "agent_setups": ["Claude Code Opus 5"],
#                     "submitted_at": "2026-08-26T09:12:04.118Z",
#                     "status": "running"}}
#
# An entry written by an earlier version of this action names the setups
# under "environments"; pending_get reads it as agent_setups, and the entry
# is rewritten under the current name the next time its status is brought
# up to date.
#
# The entry is written right after the 202 receipt, its status is brought up
# to date when the job stops waiting, and it is committed with the folder.
# The reconcile pass at the start of every job (release and sync alike)
# reads it, and the entry is cleared the moment the release's report reaches
# the folder or the release fails on the Verging side. The file is removed
# when its last entry goes.
pending_path() {
  printf '%s/releases/pending.json' "$1"
}

# pending_set FOLDER RELEASE_ID ENTRY_JSON: add or replace one entry.
pending_set() {
  local folder="$1" id="$2" entry="$3" f tmp
  f="$(pending_path "$folder")"
  mkdir -p "$folder/releases"
  if [ -f "$f" ] && ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    echo "::warning::$f is not a JSON object; starting it over"
  fi
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || printf '{}\n' > "$f"
  tmp="$(state_dir)/pending.tmp"
  jq --arg id "$id" --argjson entry "$entry" '.[$id] = $entry' "$f" > "$tmp" && mv "$tmp" "$f"
}

# pending_get FOLDER RELEASE_ID: the entry as one JSON line, or empty. An
# entry from an earlier version, keyed "environments", is read as
# agent_setups.
pending_get() {
  local f
  f="$(pending_path "$1")"
  [ -f "$f" ] || return 0
  jq -c --arg id "$2" '.[$id] // empty
    | if type == "object" and has("environments") and (has("agent_setups") | not)
      then {vendor_version, agent_setups: .environments} + (del(.environments) | del(.vendor_version))
      else . end' "$f" 2>/dev/null || true
}

# pending_set_status FOLDER RELEASE_ID STATUS: bring an entry's last status
# up to date. No-op when the release is not on record.
pending_set_status() {
  local entry
  entry="$(pending_get "$1" "$2")"
  [ -n "$entry" ] || return 0
  pending_set "$1" "$2" "$(printf '%s' "$entry" | jq -c --arg s "$3" '.status = $s')"
}

# pending_clear FOLDER RELEASE_ID: drop the entry; drop the file when empty.
pending_clear() {
  local f tmp
  f="$(pending_path "$1")"
  [ -f "$f" ] || return 0
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 0
  tmp="$(state_dir)/pending.tmp"
  jq --arg id "$2" 'del(.[$id])' "$f" > "$tmp" && mv "$tmp" "$f"
  if [ "$(jq 'length' "$f")" = "0" ]; then
    rm -f "$f"
  fi
}

# pending_ids FOLDER: every release id on record, oldest submission first.
pending_ids() {
  local f
  f="$(pending_path "$1")"
  [ -f "$f" ] || return 0
  jq -r 'to_entries | sort_by(.value.submitted_at // "") | .[].key' "$f" 2>/dev/null || true
}

# stop_waiting RELEASE_ID LAST_STATUS: the deadline passed before the report
# was ready. Nothing here is an error: the release stays on record as pending
# with its last status, this job ends green with the verdict "Pending" and no
# report path, and the notice says what happens next.
stop_waiting() {
  local id="$1" status="$2" folder
  folder="$(state_get folder)"
  pending_set_status "$folder" "$id" "$status"
  ensure_folder_readme "$folder"
  state_set release_id "$id"
  state_set verdict "Pending"
  state_set report_path ""
  state_set last_status "$status"
  echo "::notice::Verging Labs is still testing release $id (last status: $status). This job stops waiting; your next push or the sync job commits the report when it is ready. To wait longer, set poll_timeout_minutes."
  echo "The release is on record in $folder/releases/pending.json; nothing to recover by hand. To fetch the report on demand once it is ready, re-run with fetch_only_release_id=$id."
  {
    echo "### Report pending"
    echo
    echo "Verging Labs is still testing release \`$id\` (last status: \`$status\`). This job stops waiting; your next push or the sync job commits the report when it is ready. To wait longer, set \`poll_timeout_minutes\`."
    echo
    echo "The release is on record in \`$folder/releases/pending.json\`."
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
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
# is ready. Returns 0 on report_ready or corrected, 1 on failed, and 2 when
# the deadline passes first: that is not an error, the caller records the
# release as pending (stop_waiting) and the job ends green. The last status
# seen is left in the state as last_status.
poll_release() {
  local id="$1" timeout_min="$2" interval="${POLL_INTERVAL_SECONDS:-30}"
  local status_file deadline status code failure
  status_file="$(state_dir)/status.json"
  deadline=$(( $(date +%s) + timeout_min * 60 ))
  status="unknown"
  state_set last_status "$status"
  echo "Polling $(state_get api_base)/v1/releases/$id every ${interval}s for up to ${timeout_min} minute(s)"
  while :; do
    code="$(api_get "/v1/releases/$id" "$status_file")"
    if [ "$code" = "200" ]; then
      status="$(jq -r '.status // "unknown"' "$status_file")"
      state_set last_status "$status"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  status=$status  updated_at=$(jq -r '.updated_at // "-"' "$status_file")"
      case "$status" in
        report_ready|corrected)
          state_set status "$status"
          return 0
          ;;
        failed)
          failure="$(jq -r '.failure // "(no failure field on the status body)"' "$status_file")"
          echo "::error::release $id failed on the Verging side: $failure"
          echo "The release is voided; voided tests are never billed. Start a new release, or send the release_id to contact@verginglabs.com."
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
      echo "Release $id is not report_ready after ${timeout_min} minute(s); last status: $status."
      return 2
    fi
    sleep "$interval"
  done
}

# fetch_and_write RELEASE_ID RELEASE_DATE [keep-latest]: fetch the report
# and write the release directory, latest/, the index row, and the folder
# README, and clear the release from the pending record. Records
# vendor_version, verdict, slug, and report_path in the step state. With
# "keep-latest" the latest/ copy is left alone: the reconcile pass passes it
# when a newer release's report is already on record.
fetch_and_write() {
  local id="$1" release_date="$2" latest_mode="${3:-}"
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
  if [ "$latest_mode" = "keep-latest" ]; then
    echo "latest/ left as it is: a newer release's report is already on record."
  else
    refresh_latest "$folder" "$dir"
  fi
  ensure_folder_readme "$folder"

  verdict="$(extract_verdict "$report" "$dir/REPORT.md")"
  stage="$(jq -r '.diff.stage // "not recorded"' "$report")"
  rstatus="$(jq -r '.status // "not recorded"' "$report")"
  due="$(jq -r '.corrections_due_by // "-"' "$report")"
  echo "Release verdict: $verdict"
  echo "Stage: $stage   status: $rstatus   corrections_due_by: $due"

  index_put_row "$folder" "$id" \
    "| $release_date | $vendor_version | [$id]($slug/REPORT.md) | $verdict | $stage |"
  # The report is in the folder: the release is no longer pending.
  pending_clear "$folder" "$id"

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

# wiring_slug_for RELEASE_DATE VENDOR_VERSION RELEASE_ID FOLDER: the wiring
# page's directory name: the release slug with "-wiring-check" appended, so a
# real release of the same version on the same day keeps its own directory.
# A same-day repeat of the wiring check for the same version gets the id's
# short stem appended, exactly as slug_for does.
wiring_slug_for() {
  local slug="$1-$2-wiring-check" dir="$4/releases/$1-$2-wiring-check"
  if [ -d "$dir" ] && [ "$(jq -r '.release_id // empty' "$dir/release.json" 2>/dev/null)" != "$3" ]; then
    slug="$slug-$(printf '%s' "$3" | tail -c 12)"
  fi
  printf '%s' "$slug"
}

# fetch_and_write_wiring RELEASE_ID RELEASE_DATE: fetch a wiring check's page
# and write it into the report folder exactly like a report (REPORT.md,
# diff.json, release.json; a wiring check has no evidence), plus the index
# row and the folder README. latest/ is NOT touched: it holds the newest
# regression report, and a wiring page carries no verdict to gate on.
# Records vendor_version, verdict ("Wiring check"), slug and report_path in
# the step state, and marks the run as a wiring check (wiring_done).
fetch_and_write_wiring() {
  local id="$1" release_date="$2"
  local folder report code vendor_version slug dir format
  folder="$(state_get folder)"
  report="$(state_dir)/report.json"
  code="$(api_get "/v1/releases/$id/report" "$report")"
  if [ "$code" != "200" ]; then
    echo "::error::GET /v1/releases/$id/report returned HTTP $code"
    print_error_body "$report"
    return 1
  fi
  format="$(jq -r '.diff.format // empty' "$report")"
  if [ "$format" != "wiring-check/v1" ]; then
    echo "::warning::the page for $id does not carry the wiring-check format (diff.format: ${format:-not recorded}); committing it as a wiring check anyway"
  fi

  vendor_version="$(jq -r '.vendor_version // empty' "$report")"
  [ -n "$vendor_version" ] || vendor_version="$(state_get vendor_version)"
  [ -n "$vendor_version" ] || vendor_version="not-recorded"

  slug="$(wiring_slug_for "$release_date" "$vendor_version" "$id" "$folder")"
  dir="$folder/releases/$slug"
  write_release_dir "$report" "$dir" || return 1
  ensure_folder_readme "$folder"
  echo "Wiring check $id: page written to $dir/REPORT.md. Nothing was tested and nothing is billed."

  index_put_row "$folder" "$id" \
    "| $release_date | $vendor_version | [$id]($slug/REPORT.md) | Wiring check | wiring |"

  state_set vendor_version "$vendor_version"
  state_set release_id "$id"
  state_set verdict "Wiring check"
  state_set slug "$slug"
  state_set report_path "$folder/releases/$slug/REPORT.md"
  state_set wiring_done "1"

  {
    echo "### Wiring check"
    echo
    echo "This run performed the free wiring check instead of a release: nothing was tested and nothing is billed."
    echo
    echo "Page: \`$dir/REPORT.md\`"
    echo
    echo "<details><summary>Top of the page</summary>"
    echo
    head -n 60 "$dir/REPORT.md"
    echo
    echo "</details>"
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  return 0
}

# push_report_commit: push HEAD to the branch this job ran on, with a fetch
# and rebase retry. When the push is still refused the job FAILS with a named
# error that says which branch refused it and what to allow (the workflow's
# token needs push permission on that branch). Nothing else is written: no
# other branch, no pull request. The one exception is the fallback_pull_request
# input (off by default, and never honoured during a wiring check): with it
# the same commit is delivered on the branch verging-memory-ci/reports with a
# pull request into the default branch, and the job stays green.
push_report_commit() {
  local branch attempt
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

  if fallback_pull_request_wanted; then
    deliver_on_reports_branch "$branch"
    return 0
  fi
  push_refused "$branch"
  return 1
}

# fallback_pull_request_wanted: true only when the fallback_pull_request input
# is on AND this job is not a wiring check (neither the input's own wiring
# check nor a release turned into one): a wiring check's page must land on the
# branch the job ran on, or the check proves nothing.
fallback_pull_request_wanted() {
  [ "$(state_get fallback_pull_request)" = "true" ] || return 1
  if [ "$(state_get wiring_check)" = "true" ] || [ "$(state_get wiring_done)" = "1" ]; then
    echo "fallback_pull_request is on, but this job is a wiring check: its page must land on the branch the job ran on, so no other branch is written and no pull request is opened."
    return 1
  fi
  return 0
}

# push_refused BRANCH: the named error that fails the job when the push of
# the report commit was refused. It says what to allow and how to recover;
# the recovery depends on what this job was doing.
push_refused() {
  local branch="$1" id recover
  id="$(state_get release_id)"
  if [ "$(state_get wiring_done)" = "1" ]; then
    recover="Then re-run this workflow: the wiring check is free and is performed again."
  elif [ -n "$id" ]; then
    recover="Then re-run with fetch_only_release_id=$id to fetch and commit this report without submitting anything."
  else
    recover="Then re-run this workflow: the reports it collected are fetched and committed again."
  fi
  state_set push_path "refused"
  echo "::error title=Verging Memory CI push refused::The report commit could not be pushed to $branch after 3 attempts, so it is not in your repository. Nothing else was written: no other branch, no pull request. Fix: allow the workflow's token to push to $branch. The workflow needs 'permissions: contents: write', and any ruleset or branch protection on $branch must let this workflow push (exempt it in the rule, or run the workflow on a branch the rule does not cover); a pull request from a fork runs with a read-only token, so push the branch to this repository instead. $recover"
  {
    echo "## Verging Memory CI: push to \`$branch\` refused"
    echo
    echo "The report commit could not be pushed to \`$branch\` after 3 attempts, so it is not in your repository. Nothing else was written: no other branch, no pull request."
    echo
    echo "Allow the workflow's token to push to \`$branch\`: the workflow needs \`permissions: contents: write\`, and any ruleset or branch protection on \`$branch\` must let this workflow push. $recover"
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# deliver_on_reports_branch BRANCH: the fallback_pull_request delivery. The
# commit is force-pushed to verging-memory-ci/reports and a pull request into
# the default branch is opened for it, or the open one is named. The job does
# not fail on this path.
deliver_on_reports_branch() {
  local branch="$1" default_branch existing
  echo "::warning::could not push the report commit to $branch after 3 attempts; fallback_pull_request is on, so it is delivered on the branch verging-memory-ci/reports instead. The job does not fail on this."
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
