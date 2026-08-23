#!/usr/bin/env bash
# Sync mode (D4-A, 2026-08-23): the on-demand and scheduled path that puts
# the FINAL report in the repository. Submits nothing. The whole job is one
# finals sync (sync_finals_pass in lib.sh): scan the folder for releases
# still on their preliminary report, ask each one's status with the customer
# key, fetch and commit the final report for the corrected ones in one
# commit, and post one commit status per synced release. A clean no-op, with
# no commit, when nothing needs syncing. Pair it with workflow_dispatch for
# a button, and with an optional schedule trigger for a standing pickup; the
# README shows the workflow.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"

if [ "$(state_get mode)" != "sync" ]; then
  echo "mode is release; the finals sync already happened at the start of this job."
  exit 0
fi

sync_finals_pass 1
