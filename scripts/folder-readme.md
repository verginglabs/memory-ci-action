# Verging Memory CI

This folder holds the delivered Verging Memory CI regression reports for this repository.

## What is here

```
Verging Memory CI/
  README.md                      this file; written once, never overwritten
  latest/                        a plain copy of the newest release directory
    REPORT.md                    the regression report for the most recent release
    diff.json                    the machine-readable form of the same findings
    release.json                 release_id, vendor_version, scope, corrections_due_by
  releases/
    index.md                     one line per release: date, vendor_version, release id, Release verdict
    <date>-<version>/            one directory per tested release, kept
      REPORT.md
      diff.json
      release.json
      evidence/                  the files the report's Evidence pointers name, one per failed test
```

The files are written by the Verging Memory CI GitHub Action (verginglabs/memory-ci-action) after each release. Every release is delivered twice: a preliminary report as soon as testing finishes, and a final report by next business day, with any corrections from the heavier grading. The files here are whichever report the action fetched last; the `Stage` row of the report and `diff.json`'s `stage` field say which one you are holding. When a final report lands after a run already committed the preliminary one, the next run of the action fetches it and commits the update on its own.

## What Verging Memory CI tests

Every release of the memory product is run through the test suites selected in the workflow that runs the action, in real agent environments, and compared with the last release tested. The report reads out three dimensions: Accuracy, Speed, and Cost. A report over part of the suites is a verdict on the suites selected and says so in its Test suites row. The first release on an environment has nothing earlier to compare against, so that report states what was measured, and its verdict is decided on accuracy alone.

## How to read a report

1. **On a new report, read `latest/REPORT.md` top to bottom.** The Release verdict row at the top of the header table gives the call (Ready, or Not ready with the reason); the three lines under Results at a glance carry accuracy, speed, and cost.
2. **Gate on `latest/diff.json`.** `release_verdict == "not_ready"` is the report's own call. Or gate on the two dimensions separately: `verdict == "regressions_found"` (or `counts.regressed > 0`) means a test that passed on the previous release fails on this one, and `cost_verdict == "fail"` means the tests ran slower or cost more, outside expected variation. Gate on any of the three fields, as your release policy prefers; `release_verdict_reasons` names which dimensions fired.
3. **Read the failures, not just the count.** Every regression in the report carries what was asked, what the previous release answered, what this one answered, and what your memory returned to the asking session. That is usually enough to find the cause without reproducing anything.
4. **Read the Test suites row before concluding anything.** If it names fewer than every suite, the report covers only the suites selected. A clean report over part of the suites is not a clean release.
5. **Do not edit the files.** They are the delivered record. Put your own analysis in your own files.

Every term used in the reports (the verdict words, the score intervals, expected variation, the pricing basis) is defined in the reading guide: https://verginglabs.com/memory-ci/reading-guide. The integration guide is at https://verginglabs.com/memory-ci/integration.
