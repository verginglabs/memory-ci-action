#!/usr/bin/env bash
# Expose the action outputs from the step state.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"
{
  echo "release_id=$(state_get release_id)"
  echo "verdict=$(state_get verdict)"
  echo "report_path=$(state_get report_path)"
} >> "${GITHUB_OUTPUT:-/dev/null}"
