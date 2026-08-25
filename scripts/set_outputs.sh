#!/usr/bin/env bash
# Expose the action outputs from the step state, then check that the report
# this run delivered is complete.
#
# The outputs are written FIRST and the check runs last, so a report that
# reached the repository is never held back by this step: the folder is
# already committed and pushed by the time this runs. An evidence file the
# report links to that did not reach the folder is a real defect, so the job
# ends red and says which file it was, rather than ending green on a report
# whose links go nowhere.
set -euo pipefail
source "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}/scripts/lib.sh"
{
  echo "release_id=$(state_get release_id)"
  echo "verdict=$(state_get verdict)"
  echo "report_path=$(state_get report_path)"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# A wiring check ends with one notice saying what this run did and why, so
# a customer reading the run's summary never mistakes it for a release. The
# page is committed by now (the commit step ran before this one).
if [ "$(state_get wiring_done)" = "1" ]; then
  if [ "$(state_get wiring_why)" = "not_set_up" ]; then
    echo "::notice::Verging Labs has not activated the test suites on your agent setups yet, so this run performed the free wiring check instead of a release and committed its page. Verging Labs tells you when your suites are set up; pushes after that run real releases."
  else
    echo "::notice::wiring_check is true, so this run performed the free wiring check instead of a release and committed its page. Nothing was tested and nothing is billed."
  fi
fi

refused="$(state_get evidence_refused)"
case "$refused" in ''|*[!0-9]*) refused=0 ;; esac
if [ "$refused" -gt 0 ]; then
  echo "::error::$refused evidence file(s) named by this report did not reach the report folder. The report itself is committed. The names are in this run's log."
  {
    echo "**$refused evidence file(s) named by this report did not reach the report folder.** The report itself is committed; the names are in this run's log."
    echo
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi
