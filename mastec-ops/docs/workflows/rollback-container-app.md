# Rollback (`rollback-container-app.yaml`)

## Purpose

Recovery tool. It puts one service's Container Apps back on known-good images, using their digests, and checks that the restored versions are healthy. It works for a single-container service and for a service with sidecars, such as web, worker and beat. All containers in one run are rolled back together. It is manual only and is not part of the normal deploy.

## Inputs

| Name | Required | Meaning |
|---|---|---|
| `environment` | yes | `dev`, `qa` or `prod` (sets the GitHub Environment) |
| `resource_group` | yes | Resource group of the Container Apps |
| `containers` | yes | JSON array of `{"app": "...", "digest": "registry/repo@sha256:..."}`. Order is the order of change. |
| `smoke_test_url` | yes | HTTPS health URL of the service (its web app) |

Secrets, passed from the caller with `secrets: inherit`: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

Example `containers` value for a single-container service:

```json
[{"app": "qwest-users-dev", "digest": "qwestdevacr1.azurecr.io/qwest-users@sha256:..."}]
```

Example for a service with sidecars, beat first:

```json
[
  {"app": "qwest-requests-beat-dev",   "digest": "qwestdevacr1.azurecr.io/qwest-requests-beat@sha256:..."},
  {"app": "qwest-requests-worker-dev", "digest": "qwestdevacr1.azurecr.io/qwest-requests-worker@sha256:..."},
  {"app": "qwest-requests-dev",        "digest": "qwestdevacr1.azurecr.io/qwest-requests@sha256:..."}
]
```

## Flow

```
manual start (environment, resource_group, containers, smoke_test_url)
   │
1  validate inputs (nothing in Azure is touched)
     - environment is dev, qa or prod
     - resource group and URL are valid; URL is HTTPS
     - containers is a non-empty JSON array
     - each app name is valid; each digest is pinned by SHA-256
     - no app appears twice
   │
2  Azure login (OIDC)
   │
PHASE 1  check every container (nothing changes)
     for each container:
       - it exists
       - it is in Single revision mode        ← otherwise stop
       - read its current image and revision
       - action = skip if it already runs the requested digest, else change
     any check fails → stop; no container was changed
     every container already on its digest → stop; nothing to roll back
   │
PHASE 2  change each container, in order
     az containerapp update --image <digest>  for each "change" container
     a failure → stop and report which containers already changed
   │
PHASE 3  wait for each container
     changed:  wait for a NEW revision, Provisioned and Running, on the digest
     skipped:  its latest revision is Running on the digest
     5 minute limit per container
   │
4  health check on smoke_test_url, 12 tries, 10 seconds apart
   │
5  summary: one row per container, with previous image, requested image and action
```

Why Single mode is required: in Multiple mode, Azure does not move traffic to the new revision, so the job could report success while users still hit the bad one.

Why Phase 1 checks everything first: a bad input or a bad app should stop the run before any container changes, so the service isn't left half rolled back.

## Where the previous digest comes from

The deploy workflow writes each container's previous image to its run summary, before it changes the app. That's the digest to roll back to. The rollback also reads the current image itself in Phase 1, so the summary is for reference.

## How to call it

From a service repo's manual caller, or from `mastec-ops/.github/workflows/rollback.yml` for testing:

```yaml
jobs:
  rollback:
    uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/rollback-container-app.yaml@main
    with:
      environment: ${{ inputs.environment }}
      resource_group: ${{ inputs.resource_group }}
      containers: ${{ inputs.containers }}
      smoke_test_url: ${{ inputs.smoke_test_url }}
    secrets: inherit
```

Pin to a commit SHA for prod.

## How to test

Use a dev service and digests you are happy to roll back to.

1. Note each container's current image, from the deploy summary or the Azure portal.
2. **Single container:** run with one entry, on `dev`. Check the summary row.
3. **Sidecars:** run with three entries, beat first. Check that all three rows show `change` and that each container ends on its digest.
4. **Partial:** run with one container already on its digest, and the others not. Check that it shows `skip` for that one, and `change` for the rest.
5. Negative tests, on dev:
   - a tag instead of a digest → fails at validation, nothing changed
   - an `http://` URL → fails at validation
   - the same app listed twice → fails at validation
   - one app in Multiple mode → fails in Phase 1, and no other container is changed
   - every container already on its digest → fails with "Nothing to roll back"

## Known limits

- **No automatic revert.** If Phase 2 or the health check fails, the containers that changed stay on the restored digest. The run reports which ones; someone decides the next step.
- **Partial changes.** If Phase 2 fails halfway, the service is mixed until the rest is fixed.
- **Digests must be known.** Each container needs its known-good digest, from the deploy summary.
- **Health is checked on the web URL only.** Worker and beat are checked through their Container App state, not an endpoint.
- **Runner.** Runs on `nprd-git-runner-001` with `[self-hosted, linux, x64]`.
- **Untested.** No run has happened yet.
