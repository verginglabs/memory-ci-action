# Verging Memory CI GitHub Action

Submits a release of your memory product to Verging Memory CI, waits for the regression report, and commits the report into a folder in your repository. Every run also posts a commit check with the Release verdict, and on pull requests, one comment linking the report.

Verging Memory CI runs each release of your memory tool through the test suites you chose, in real agent environments, and reports what broke, what got fixed, and what is still failing against the last release tested. The integration contract is at https://verginglabs.com/memory-ci/integration and the report vocabulary at https://verginglabs.com/memory-ci/reading-guide.

## Quick start

```yaml
name: Verging Memory CI
on:
  push:
    branches: [main]
permissions:
  contents: write
  checks: write
  pull-requests: write
concurrency:
  group: verging-memory-ci-${{ github.ref }}
  cancel-in-progress: false
jobs:
  memory-ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: "Verging Memory CI"
          sparse-checkout-cone-mode: true
      - uses: verginglabs/memory-ci-action@v1
        with:
          api_key: ${{ secrets.VERGING_API_KEY }}
          environment: staging-mcp
```

Set the repository secret `VERGING_API_KEY` to the API key issued at onboarding, and set `environment` to the environment name you registered. That is the whole integration.

### The checkout

The action needs a checkout (it commits the report into your repository), but it does not need your source. The sparse checkout above puts only the report folder and the files at the repository root on the runner's disk; your source tree never leaves your git host. A full `actions/checkout@v4` with no `sparse-checkout` works exactly the same way if you prefer it.

### The permissions

| Permission | Why the action needs it |
|---|---|
| `contents: write` | to commit and push the report folder |
| `checks: write` | to post the "Verging Memory CI" check with the Release verdict |
| `pull-requests: write` | to post the report comment on pull requests, and to open the recovery pull request if a direct push is not possible |

## Inputs

| Input | Required | Default | What it is |
|---|---|---|---|
| `api_key` | yes | | Your Verging Memory CI API key, from a repository secret. |
| `environment` | yes | | The name of the environment to test in, as you named it at onboarding or via `POST /v1/environments`. |
| `suites` | no | `core-recall,preference-adherence,truth-maintenance` | Comma separated test suite values. Pass an empty string for Full Coverage (every test suite). |
| `vendor_version` | no | the `VERSION` file at the repository root, else the short commit SHA | The identifier of the release to test. Letters, digits, dots, underscores, plus signs, and hyphens only; up to 64 characters; must not start with a hyphen. |
| `endpoint` | no | `cfg:standing` | Your staging endpoint, or the standing configuration reference agreed at onboarding. The default means "use the standing configuration on file for my account". |
| `api_base` | no | `https://ci.verginglabs.com` | Base URL of the Verging Memory CI API. |
| `folder` | no | `Verging Memory CI` | Name of the report folder at the repository root. |
| `product_name` | no | the name agreed at onboarding | Your product's name as it should appear on the report. Same character rule as `vendor_version`; a bad value fails the run before anything is submitted. |
| `fetch_only_release_id` | no | | Fetch and commit an existing release's report without submitting anything. See Recovery below. |
| `poll_timeout_minutes` | no | `45` | How many minutes to wait for the report before giving up. |

## Outputs

| Output | What it is |
|---|---|
| `release_id` | The id of the release whose report this run fetched. |
| `verdict` | The Release verdict from the report header: `Ready`, or `Not ready` with the reason. |
| `report_path` | Repository relative path of the committed `REPORT.md` for this release. |

## What lands in your repository

```
Verging Memory CI/
  README.md                      what the folder is and how to read a report; written once
  latest/                        a plain copy of the newest release directory
    REPORT.md
    diff.json
    release.json
  releases/
    index.md                     one line per release: date, version, release id, verdict, stage
    <date>-<version>/            one directory per tested release, kept
      REPORT.md                  the regression report, written for a human
      diff.json                  the same findings, machine readable; gate on release_verdict
      release.json               release_id, vendor_version, scope, corrections_due_by
      evidence/                  one file per failed test; absent when every test passed
```

The commit lands on the branch that triggered the run. If that push is not possible (a protected branch, or a race with other pushes after three rebase retries), the job does not fail: the same commit is delivered on the branch `verging-memory-ci/reports`, and the action opens (or updates) a pull request titled "Verging Memory CI reports" into your default branch. The run log says plainly which of the two happened.

## The check and the pull request comment

Every run posts a check named "Verging Memory CI" on the tested commit: conclusion `success` when the Release verdict is Ready, and conclusion `neutral` otherwise (Not ready, and refusals such as a changed agent-facing surface). The check is never a failure: it reports the verdict on your release, it does not block your pipeline. Gate on the `verdict` output or on `diff.json` if you want a blocking gate.

On `pull_request` triggers the action also maintains one comment on the pull request with the verdict, the release id, and a link to the committed report. Later runs update the same comment rather than adding new ones. If posting the check or the comment fails, the run logs a warning and carries on; the committed report is never held hostage by a permissions gap.

## Recovery: a run that failed after submitting

Submitting is not idempotent: every accepted submission is a billable release. If a run fails after the receipt was printed (a timeout, a runner outage, a push problem), do not start a new release for the same version. Take the `release_id` from the receipt in the failed run's log and re-run with:

```yaml
      - uses: verginglabs/memory-ci-action@v1
        with:
          api_key: ${{ secrets.VERGING_API_KEY }}
          environment: staging-mcp
          fetch_only_release_id: run_20260815_186efbad9769
```

That fetches the finished report, commits it exactly like a normal run, and submits nothing.

## The final report

Every release is delivered twice: the preliminary report as soon as the release finishes, and the final report, with any corrections from the heavier grading, by next business day. The action does not wait for the final report. At the start of every run it checks the releases already in your folder, and any release whose final report is now out gets its directory rewritten and committed automatically. Nothing to configure, nothing to remember.

## What can this action access

The plain answer: it runs in your GitHub account, on your runner. Verging is granted nothing on your side and never receives your code; the release submission carries your version string, your endpoint or standing configuration reference, and your suite selection, nothing else. The job's `GITHUB_TOKEN` stays in your runner and is used only for the push, the check, and the pull request comment. With the sparse checkout above, your source is not even on the runner's disk. The action reads and writes the report folder, the `VERSION` file at the repository root (for the default `vendor_version`), and its own scripts; nothing else is read, printed, or uploaded.
