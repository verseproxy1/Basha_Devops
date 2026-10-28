# Build and push images (`build-push-acr.yml`)

## Purpose

Builds the Docker image for every service in a service repo's manifest, pushes each one to the environment's Azure Container Registry (ACR), and outputs the pushed image as a digest. The deploy step then deploys that exact image.

## Inputs and outputs

| Name | Type | Required | Meaning |
|---|---|---|---|
| `environment` | input | yes | `dev`, `qa` or `prod` |
| `manifest_path` | input | yes | Caller's manifest, relative to the caller repo root |
| `images` | output | | JSON map from service key to digest-pinned image, e.g. `{"qwest-requests":"qwestdevacr1.azurecr.io/qwest-requests@sha256:..."}` |

## Flow

```
caller starts (environment = dev)
   │
1  check out the caller repo (Dockerfiles, manifest)
2  read clientId, tenantId, subscription for the environment
3  log in to Azure with OIDC
4  set up Docker Buildx
5  read the registry name (acr) for the environment
6  az acr login
   │
7  for each service in the manifest:
      read dockerfile (default Dockerfile) and repository (default = service key)
      docker buildx build --push
         tags: <run-id> and latest
         cache from the latest tag
      read the pushed digest from the build metadata
      add service → digest-pinned reference to the images map
   │
8  write the images map to the job output
```

Each service gets its own image. Requests has three services (`qwest-requests`, `qwest-requests-worker`, `qwest-requests-beat`), so it produces three images.

## How to call it

```yaml
build:
  uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/build-push-acr.yml@main
  with:
    environment: dev
    manifest_path: qwest-requests-env-manifest.json
  secrets: inherit
```

Read a service's image in a later job:

```yaml
image: ${{ fromJSON(needs.build.outputs.images)['qwest-requests'] }}
```

Needs `permissions: id-token: write` in the caller.

## How to test

1. Run the caller on `dev`.
2. Check the job log: each service should show `Building <service>` and then a digest.
3. Check the job output `images`: one entry per service, each ending in `@sha256:` followed by 64 hex characters.
4. In the Azure portal, open the dev ACR, then the repository for each service. Confirm the run-ID tag and `latest` exist, and that the digest matches the output.
5. Negative test: change one `dockerfile` in the manifest to a name that doesn't exist. Expect the build for that service to fail, and no output to be written.

## Known limits

- **Untested.** The metadata field `containerimage.digest` is assumed. If the digest is empty, the step fails with "No digest returned"; check the log and the buildx version.
- **Sequential.** Services are built one after another. It's simple and fine for three images, but slow for many.
- **Dockerfile BuildKit secrets.** The private pip feed must be passed as a BuildKit secret. Dockerfiles aren't updated yet.
- **Tickets worker and beat.** Their entrypoint commands are commented out, so those images start but do no work. Fix before building them.
