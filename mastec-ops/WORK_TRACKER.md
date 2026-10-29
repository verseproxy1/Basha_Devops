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
| 1 | Create `mastec-ops` repo and `.github/workflows` | Done | Basha | Path: `Mastec-Quadgen-AzureApps/mastec-ops` |
| 2 | Copy rollback workflow and guide into `mastec-ops` | Done | Basha | File kept as `rollback-container-app.yaml` |
| 3 | Fix rollback caller `uses:` path | Done | Basha | Temporary `@main`; pin to SHA before prod |
| 4 | Set rollback runner to `[self-hosted, linux, x64]` | Done | Basha | Runner `nprd-git-runner-001` is on the private network |
| 5 | Add single-revision check to rollback | Done | Basha | Not run yet |
| 6 | Add explanatory comments to workflow files | Done | Basha | |
| 7 | Write `APPROACH.md` and the online doc | Done | Basha | Online doc missing the review sections; re-sync if needed |
| 8 | Update rollback for a list of containers per service | Not started | Basha | Rollback must restore a service as a set |
| 9 | Write shared `build-push-acr` workflow | Done (untested) | Basha | Builds every service in the manifest, outputs digests |
| 10 | Write shared `deploy-container-apps` workflow | Done (untested) | Basha | Loops over `containerApps`, checks beat replicas, polls health |
| 10a | Write shared `secret-scan` workflow and central gitleaks config | Done (untested) | Basha | Pinned gitleaks v8.18.4; confirm version before use |
| 10b | Copy the three scripts into `mastec-ops/scripts` | Done (untested) | Basha | Copied from users; manifest path now comes from `MANIFEST_PATH` |
| 10c | Move RBAC setup into shared `rbac-setup` workflow | Done (untested) | Basha | Reusable, dry run by default, runs as the management identity |
| 10d | Resolve drift between users and requests copies of the scripts | Not started | Basha | Only the users copy was moved; diff the requests copy first |
| 11 | Check sidecar coverage (requests, tickets, users, reporting) | Not started | Basha | Worker and beat for each app |
| 12 | Dev test of rollback, including `secrets: inherit` | Blocked | Basha | Needs a dev target: app name, resource group, health URL |
| 13 | Confirm pilot repo and its migration status | Blocked | Basha with Ethan | `qwest_ssh_service_forwarder` status conflicts |
| 14 | Get Basha's GitHub access to the MIQ repo | Blocked | Basha | Access missing for about a week |
| 15 | Confirm Azure support for wildcard OIDC subjects | Not started | Basha with Azure admin | Recommendation: one credential per repo and environment |
| 16 | Confirm `nprd-git-runner-001` has Docker | Not started | Basha | |
| 17 | Add BuildKit pip-feed secret to Dockerfiles | Not started | Basha | Test on one repo |
| 18 | Replace Gmail SMTP with Office 365 | Not started | Basha, flag to Prudhvi | List apps that depend on it |
| 19 | Key Vault migration for QA and prod (QWEST, MIQ) | Not started | Migration owner | About five runs; tracked in a spreadsheet |
| 20 | Migrate the six cleaned QWEST repos, then four more | Not started | Ethan | Confirm the count |
| 21 | Decide the rule for ADO and GitHub pipelines overlapping | Not started | Team | One pipeline per repo and branch |
| 22 | Commit approved approach as HTML in the docs folder | Not started | Team | After the team agrees |
| 23 | Write one doc per workflow (flow, inputs, testing, limits) in `docs/workflows/` | Done | Basha | Index in `docs/workflows/README.md` |
| 24 | Push `mastec-ops` to GitHub on a branch | Blocked | Basha | Destination `verseproxy1/Basha_Devops` was blocked; confirm org repo or allow the push |

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
