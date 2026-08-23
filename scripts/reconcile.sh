#!/usr/bin/env bash
# The finals sync, run at the start of every release-mode job before
# anything is submitted: every release in the folder that is still on its
# preliminary report is asked about, and where the final report is out, the
# release directory is replaced in place, latest/ and the index are updated,
# and the change is committed and pushed (sync_finals_pass in lib.sh).
# Reports are never lost to a job that happened before the final report was
# out: an active customer gets every final report with zero extra
# configuration. In sync mode the sync step does this work instead.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ "$(state_get mode)" = "sync" ]; then
  echo "mode is sync; the sync step collects the final reports on this job."
  exit 0
fi

sync_finals_pass 0
