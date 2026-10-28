# Work tracker: shared workflows (mastec-ops)

Last updated: 2026-10-28. Update this file when a task changes state. Claude Code reads it at the start of a session.

## Status key
- **Done:** finished and checked.
- **In progress:** being worked on now.
- **Blocked:** waiting on someone or something, named in the notes.
- **Not started:** planned, no work yet.

## Tasks

| # | Task | Status | Owner | Notes |
|---|---|---|---|---|
| 1 | Create `mastec-ops` repo and `.github/workflows` | Done | Ankit | Path: `Mastec-Quadgen-AzureApps/mastec-ops` |
| 2 | Copy rollback workflow and guide into `mastec-ops` | Done | Ankit | File kept as `rollback-container-app.yaml` |
| 3 | Fix rollback caller `uses:` path | Done | Ankit | Temporary `@main`; pin to SHA before prod |
| 4 | Set rollback runner to `[self-hosted, linux, x64]` | Done | Ankit | Runner `nprd-git-runner-001` is on the private network |
| 5 | Add single-revision check to rollback | Done | Ankit | Not run yet |
| 6 | Add explanatory comments to workflow files | Done | Ankit | |
| 7 | Write `APPROACH.md` and the online doc | Done | Ankit | Online doc missing the review sections; re-sync if needed |
| 8 | Update rollback for a list of containers per service | Not started | Ankit | Rollback must restore a service as a set |
| 9 | Write shared `build-push-acr` workflow | Done (untested) | Ankit | Builds every service in the manifest, outputs digests |
| 10 | Write shared `deploy-container-apps` workflow | Done (untested) | Ankit | Loops over `containerApps`, checks beat replicas, polls health |
| 10a | Write shared `secret-scan` workflow and central gitleaks config | Done (untested) | Ankit | Pinned gitleaks v8.18.4; confirm version before use |
| 10b | Copy the three scripts into `mastec-ops/scripts` | Done (untested) | Ankit | Copied from users; manifest path now comes from `MANIFEST_PATH` |
| 10c | Move RBAC setup into shared `rbac-setup` workflow | Done (untested) | Ankit | Reusable, dry run by default, runs as the management identity |
| 10d | Resolve drift between users and requests copies of the scripts | Not started | Ankit | Only the users copy was moved; diff the requests copy first |
| 11 | Check sidecar coverage (requests, tickets, users, reporting) | Not started | Ankit with Basha | Worker and beat for each app |
| 12 | Dev test of rollback, including `secrets: inherit` | Blocked | Ankit | Needs a dev target: app name, resource group, health URL |
| 13 | Confirm pilot repo and its migration status | Blocked | Ankit with Ethan | `qwest_ssh_service_forwarder` status conflicts |
| 14 | Get Basha's GitHub access to the MIQ repo | Blocked | Basha | Access missing for about a week |
| 15 | Confirm Azure support for wildcard OIDC subjects | Not started | Ankit with Azure admin | Recommendation: one credential per repo and environment |
| 16 | Confirm `nprd-git-runner-001` has Docker | Not started | Ankit | |
| 17 | Add BuildKit pip-feed secret to Dockerfiles | Not started | Ankit | Test on one repo |
| 18 | Replace Gmail SMTP with Office 365 | Not started | Ankit, flag to Prudhvi | List apps that depend on it |
| 19 | Key Vault migration for QA and prod (QWEST, MIQ) | Not started | Migration owner | About five runs; tracked in a spreadsheet |
| 20 | Migrate the six cleaned QWEST repos, then four more | Not started | Ethan | Confirm the count |
| 21 | Decide the rule for ADO and GitHub pipelines overlapping | Not started | Team | One pipeline per repo and branch |
| 22 | Commit approved approach as HTML in the docs folder | Not started | Team | After the team agrees |

## Decisions made
- Repo name: `mastec-ops`.
- OIDC: one federated credential per repo and environment.
- Sidecars: one service entry with a `containerApps` list.
- Prod callers pinned to a commit SHA.
- Rollback is manual only.
- Runner: `nprd-git-runner-001`.

## Where to look
- Approach and open questions: `APPROACH.md`
- Rollback workflow: `.github/workflows/rollback-container-app.yaml`
- Rollback caller: `.github/workflows/rollback.yml`
- Rollback guide: `azure-container-app-rollback-guide.md`
