# Shared workflows: index

Reusable GitHub workflows and scripts used by the QWEST service repos. They live in `Mastec-Quadgen-AzureApps/mastec-ops`. Each service repo calls them with `uses:` and supplies its own Dockerfiles, manifest, and a short caller file.

| Workflow | File | What it does | Status |
|---|---|---|---|
| [Build and push images](build-push-acr.md) | `build-push-acr.yml` | Builds each service's image and pushes it to ACR | Written, not run |
| [Deploy container apps](deploy-container-apps.md) | `deploy-container-apps.yml` | Updates a service's Container Apps and waits until healthy | Written, not run |
| [Secret scan](secret-scan.md) | `secret-scan.yml` | Scans the repo for committed secrets with gitleaks | Written, not run |
| [RBAC setup](rbac-setup.md) | `rbac-setup.yml` | One-time grant of registry and Key Vault access | Written, not run |
| [Rollback](rollback-container-app.md) | `rollback-container-app.yaml` | Restores a known-good image by digest | Written, not run; one container per run |

## How they fit together

```
service repo caller
  ├─ secret-scan ───────────────► pass or fail the check
  ├─ build-push-acr ────────────► images (one digest per service)
  └─ deploy-container-apps ─────► Container Apps updated and healthy

manual, when needed
  ├─ rbac-setup ────────────────► managed identities get AcrPull and Key Vault access
  └─ rollback ──────────────────► a service goes back to a known-good image
```

## Shared rules

- **Inputs come from the caller.** Nothing service-specific is written into a workflow.
- **No secret values** in any workflow or script. Secrets are read from Key Vault.
- **Pin prod callers to a commit SHA.** `@main` is for testing only.
- **Scripts** are in `scripts/` and are checked out by each workflow at `shared/scripts/`.

## Known gaps (apply to all workflows)

- Nothing has been run yet. Expect a few fixes on the first runs.
- The `secrets: inherit` behaviour for environment-level secrets is untested.
- The runner `nprd-git-runner-001` must have Docker. Not yet confirmed.
- Sidecar services need one image per container. The deploy workflow currently sends one image to every container. See the deploy doc.
