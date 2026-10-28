# RBAC setup (`rbac-setup.yml`)

## Purpose

A one-time setup, run by hand. It makes sure every container app in a service's manifest has:

- a system-assigned managed identity,
- **AcrPull** on the environment's container registry,
- **Key Vault Secrets User** on the environment's Key Vault.

The deploy workflow checks these before it changes anything, so the setup must be done first for a new app or environment.

It runs with the runner VM's managed identity, which has more rights than the deploy's OIDC login. That's why it's kept separate, is manual only, and does a dry run by default.

## Inputs

| Name | Required | Meaning |
|---|---|---|
| `environment` | yes | `dev`, `qa` or `prod` |
| `manifest_path` | yes | Caller's manifest path |
| `dry_run` | no | Default `true`. Reports what would change without changing anything. |
| `mgmt_identity_client_id` | yes | Client ID of the runner VM's managed identity. Pass it from the caller's variables. |
| `shared_ref` | no | mastec-ops branch, tag or commit for the scripts. Default `main`. |

## Flow

```
manual start (environment, dry_run)
   │
1  check out the caller repo and shared scripts
2  az login --identity (runner VM's managed identity)
3  setup-kv-rbac.sh <environment> [--dry-run]
     - read resourceGroup, acr and vault from the manifest
     - look up the ACR and Key Vault resource IDs
     - for each container app in every service:
         - enable the system-assigned identity, if missing
         - grant AcrPull on the ACR, if missing
         - grant Key Vault Secrets User on the vault, if missing
     - print a summary table
```

Re-running it is safe. Anything already in place is skipped.

## How to call it

Make a manual caller in the service repo:

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, qa, prod]
        required: true
      dry_run:
        type: boolean
        default: true

jobs:
  rbac:
    uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/rbac-setup.yml@main
    with:
      environment: ${{ inputs.environment }}
      manifest_path: qwest-users-env-manifest.json
      dry_run: ${{ inputs.dry_run }}
      mgmt_identity_client_id: ${{ vars.MGMT_VM_IDENTITY_CLIENT_ID }}
    secrets: inherit
```

## How to test

1. Run the caller on `dev` with `dry_run` on.
2. Read the summary table. Each container app should show `DRY-RUN-PENDING` or `ENABLED` / `GRANTED`, and the log should list what would be created. Nothing should change in Azure.
3. Check the same app in the Azure portal: no new role assignments should exist.
4. Run again with `dry_run` off, on dev only.
5. Confirm in the portal that the identity is enabled and that both roles appear on the ACR and the vault.
6. Run the caller a second time with `dry_run` off. Every row should show `ENABLED` and `GRANTED`, with no new changes. This shows the setup is idempotent.
7. Then run `deploy-container-apps` with `skip_kv_check` off. Its pre-deploy checks should pass.

## Known limits

- **Who can run it.** The runner's managed identity must be allowed to create role assignments. Check this before the first live run.
- **`vars` in a reusable workflow.** The caller passes the client ID in, because variables may not resolve inside a reusable workflow. Confirm this on the first run.
- **Untested.** The live run hasn't happened.
- **Requests copy not compared.** The script is from the users repo.
