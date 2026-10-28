# Rollback (`rollback-container-app.yaml`)

## Purpose

Recovery tool. It puts a Container App back on a known-good image, using its digest, and checks that the restored revision becomes healthy. It is manual only and is not part of the normal deploy.

## Inputs

| Name | Required | Meaning |
|---|---|---|
| `app_name` | yes | Container App name, e.g. `qwest-users-dev` |
| `resource_group` | yes | Resource group of the app |
| `environment` | yes | `dev`, `qa` or `prod` (sets the GitHub Environment) |
| `image_ref` | yes | Known-good image pinned by digest: `registry/image@sha256:<64 hex>` |
| `smoke_test_url` | yes | HTTPS health URL of the app |

Secrets, passed from the caller with `secrets: inherit`: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

## Flow

```
manual start
   │
1  validate inputs
     - environment is dev, qa or prod
     - app name and resource group are valid
     - image is pinned by digest
     - health URL is HTTPS
2  Azure login (OIDC)
3  the app exists
4  the app is in Single revision mode   ← otherwise stop
5  record the current image and revision
6  stop if the app already runs this image
7  az containerapp update --image <digest>
8  wait up to 5 minutes for a new revision that is Provisioned, Running,
   and runs the requested image
9  health check, 12 tries, 10 seconds apart
10 summary on the run page
```

Why Single mode is required: in Multiple mode, Azure does not move traffic to the new revision, so the job could report success while users still hit the bad one.

## How to call it

From the mastec-ops repo itself (testing), or from a service repo's manual caller:

```yaml
jobs:
  rollback:
    uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/rollback-container-app.yaml@main
    with:
      app_name: ${{ inputs.app_name }}
      resource_group: ${{ inputs.resource_group }}
      environment: ${{ inputs.environment }}
      image_ref: ${{ inputs.image_ref }}
      smoke_test_url: ${{ inputs.smoke_test_url }}
    secrets: inherit
```

## How to test

Use a dev app and an image you are happy to roll back to.

1. Record the app's current image, from the Azure portal or the deploy summary.
2. Run the rollback on `dev` with an older digest.
3. Check the summary: previous image, previous revision, requested image, result.
4. In the portal, confirm the new revision runs the requested digest and is healthy.
5. Negative tests, on dev:
   - a tag instead of a digest → fails at validation
   - an `http://` URL → fails at validation
   - the same image as the current one → fails with "Already on this image"
   - an app in Multiple mode → fails at the revision-mode check

## Known limits

- **One container per run.** A service with web, worker and beat needs three runs, and they aren't tied together yet. This is the main gap. It needs a loop over the service's containers, which isn't written.
- **No automatic revert.** If the health check fails, the restored revision stays live.
- **Digest needed.** Each app needs a known-good digest. Deploys don't record one yet.
- **Runner.** Runs on `nprd-git-runner-001` with `[self-hosted, linux, x64]`.
- **Untested.** No run has happened.
