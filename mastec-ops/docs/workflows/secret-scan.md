# Secret scan (`secret-scan.yml`)

## Purpose

Scans the whole git history of a service repo for committed secrets, using gitleaks with the central config. It runs on the server, so it can't be skipped by a developer who hasn't installed the local hook. When it's required in the branch ruleset, a finding blocks the merge.

## Inputs

| Name | Required | Meaning |
|---|---|---|
| `shared_ref` | no | mastec-ops branch, tag or commit for the gitleaks config. Default `main`. |

## Flow

```
push or pull request in a service repo
   │
1  check out the caller repo with full history (fetch-depth 0)
2  check out mastec-ops into shared/ (for the config)
3  run gitleaks (pinned image v8.18.4) with shared/gitleaks/.gitleaks.toml
     - scans the whole repo, including history
     - redacts found values in the log
   │
   ├─ finding → job fails → check fails → merge blocked (if required)
   └─ none    → job passes
```

## How to call it

```yaml
scan:
  uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/secret-scan.yml@main
```

Call it from a workflow that runs on `push` and `pull_request`. Once it works, mark its check as required in the organization ruleset for protected branches.

## How to test

1. In a test repo, create a branch and add a file containing a fake credential, for example `API_KEY = "fake-test-value-123"`.
2. Push the branch. Expect the scan job to fail and the log to show a finding, with the value redacted.
3. Remove the file, push again. Expect a pass.
4. Check that a test file (`tests.py`) with dummy values is not reported, because the config allowlists it.

## Known limits

- **Untested.** Confirm the gitleaks image tag `v8.18.4` exists before the first run.
- **The shared repo is scanned too.** The `shared/` checkout sits inside the workspace, so the scan also reads the mastec-ops files. Those files contain no secret values, so this is harmless, but it adds time.
- **Ruleset not set.** Making the check required is an organization setting. Until it's set, the scan reports but doesn't block merges.
