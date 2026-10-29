# Deploy container apps (`deploy-container-apps.yml`)

## Purpose

Updates one service's Azure Container Apps to a new image, then waits until every container is Running and Healthy. It checks the manifest first, then runs the pre-deploy checks, so a bad setup stops before anything changes.

## Inputs

| Name | Required | Meaning |
|---|---|---|
| `environment` | yes | `dev`, `qa` or `prod` |
| `service` | yes | Service key in the manifest, e.g. `qwest-users` |
| `image` | yes | Digest-pinned image, from the build step |
| `manifest_path` | yes | Caller's manifest path |
| `shared_ref` | no | mastec-ops branch, tag or commit for the scripts. Default `main`. Use a commit SHA for prod. |
| `skip_kv_check` | no | Skips the advisory Key Vault secret check. Default `false`. |

## Flow

```
caller starts (environment, service, image)
   │
1  check out the caller repo
2  check out the shared scripts into shared/
3  validate the manifest
     - the service exists and lists at least one container app
     - every celery-beat service has maxReplicas 1
4  read clientId, tenantId, subscription
5  log in to Azure with OIDC
5b check every container app is in Single revision mode
     any app in Multiple mode → stop before any change
6  pre-deploy checks (shared/scripts/pre-deploy-checks.sh)
     - each container app exists
     - each has a system-assigned identity
     - that identity has AcrPull and Key Vault Secrets User
   │
7  for each container app in the service's list:
     generate its config (secrets as Key Vault references, the image)
     az containerapp update --yaml … --no-wait
   │
8  wait for every container app: Running and Healthy (10 minute limit each)
     any app that doesn't come up → job fails and names it
```

Beat runs as exactly one copy, because the manifest check fails if a beat service's `maxReplicas` is not 1.

## How to call it

```yaml
deploy:
  needs: build
  uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/deploy-container-apps.yml@main
  with:
    environment: dev
    service: qwest-users
    image: ${{ fromJSON(needs.build.outputs.images)['qwest-users'] }}
    manifest_path: qwest-users-env-manifest.json
  secrets: inherit
```

## How to test

1. Use a dev app that is safe to redeploy. Note its current image first, so you can roll back.
2. Run the caller on `dev`.
3. Check the pre-deploy output: each container app should say `[OK]`. If one fails with "missing AcrPull" or "missing Key Vault Secrets User", run `rbac-setup` (dry run first) for that environment.
4. In the Azure portal, open the Container App. Confirm a new revision exists, with the new digest in its image.
5. Check the health step: each app should print `Running` and `Healthy`.
6. Negative test: set a wrong image digest (for example, all zeros). Expect the update to fail, and the job to name the app.
7. Beat check: temporarily set a beat service's `maxReplicas` to 2 in a test branch. Expect the manifest check to fail before anything is deployed.

## Known limits

- **One image per service.** This is the main gap. The step sends the same `image` to every container in the list. A service with web, worker and beat images needs one image per container, which the manifest and the workflow don't support yet. Until that is done, deploy each service separately, using its own image.
- **No automatic rollback.** If a container doesn't become healthy, the job fails, but the new revision stays live. Use the rollback workflow to recover.
- **Scripts are from the users repo.** The requests copies haven't been compared.
- **Requests manifest.** Its secrets are in `sharedVars`, which the scripts don't read yet.
- **Untested.** The first run may surface issues in the health check or the generated config.
