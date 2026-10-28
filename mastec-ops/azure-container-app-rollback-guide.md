# Azure Container App Rollback — Implementation & Operations Guide

**Status:** Implementation guide for the reusable GitHub Actions workflow and its caller
**Scope:** Manually roll back **any** Azure Container App (dev, qa or prod) to a previously published image, then verify that a **new revision** is running that image and that an application health endpoint responds.
**Important:** Treat this as a pre-production guide. Do not enable production execution until the Azure identity, runner connectivity, image validation and failure-recovery behavior have been reviewed. The workflow has been syntax-checked only; it has **not** been run against a live Azure environment.

**Revision notes (this version):**

- Generic target: `app_key` allowlist removed; the caller passes `app_name` and `resource_group`.
- `dev`, `qa` and `prod` are all accepted.
- Revision wait fixed: the workflow now waits for a revision *different from the one recorded before the update* and requires it to run the requested image.
- Same-image check added (Fix 2): if the app already runs the requested image, the workflow now fails immediately with an "Already on this image" message instead of waiting 300 s for a timeout.
- The Azure identity still comes from GitHub secrets (main design). **Section 13** is a separate appendix that lists exactly what to change if the identity must be read from an environment manifest instead.

---

## 1. Overview

Two workflow files:

```text
qg-devops-workflows/
└── .github/
    └── workflows/
        └── rollback-container-app.yml   # reusable workflow

<application-repo>/                      # any application repository
└── .github/
    └── workflows/
        └── rollback.yml                 # manual caller
```

The reusable file delivered during implementation is named `reusable-containerapp-rollback.yml`. Either rename it to `rollback-container-app.yml` when committing, or use the real file name in the caller's `uses:` line. The two must match exactly.

### Execution flow

1. An operator opens **Actions → Rollback Container App → Run workflow** in the application repository and fills in `app_name`, `resource_group`, `environment`, `image_ref` and `smoke_test_url`.
2. GitHub invokes the reusable workflow at a pinned commit SHA.
3. **Validate inputs:** environment is `dev`, `qa` or `prod`; app name and resource group match Azure naming rules; `image_ref` is pinned to `@sha256:<64 hex>`; `smoke_test_url` is HTTPS.
4. GitHub issues an OIDC token because the workflow has `id-token: write`. `azure/login` exchanges it with Microsoft Entra ID using a federated credential, with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` taken from GitHub secrets. No Azure client secret is used.
5. Azure CLI verifies the app exists and **records the current image and revision**. If the current image is already identical to `image_ref`, the workflow **stops here with an "Already on this image" error** and changes nothing.
6. Azure CLI updates the Container App to the requested image.
7. The workflow **waits for a new revision** (name different from the recorded one) that is `Provisioned`, `Running`, and whose image equals `image_ref`.
8. A health check runs from the runner (up to 12 attempts, 10 s apart).
9. The run summary records the app, resource group, previous image/revision and requested image.

### Important behavior of the current implementation

- **No target allowlist.** Any app name and resource group that pass the format checks are accepted. Safety now depends on: the scope of the Azure federated credential and RBAC role, GitHub Environment approvals, deployment-branch restrictions, and who may run the workflow. For production, consider re-adding a reviewed allowlist.
- **`smoke_test_url` is operator-supplied.** A private runner will request whatever HTTPS URL is typed. Before production, derive it from reviewed configuration, or restrict it to approved hostnames.
- **Image check is syntax only.** It confirms a SHA-256 digest is present; it does not prove the image belongs to an approved registry/repository. Add registry/repository allowlisting.
- **Revision wait is fixed (Fix 1).** The old logic could pass on the *previous* revision right after the update. The new logic requires a new revision running the requested image.
- **Same-image case is handled (Fix 2).** If `image_ref` is already the running image, Azure would create no new revision. The workflow detects this right after recording the current image and fails immediately with "Already on this image", before any change. This is deliberately a **failure**, not a success: supplying the running image usually means the wrong digest was chosen. Note the comparison is an exact string match against the image reference stored in the app; the same image written differently (for example a tag-based reference currently deployed) will not match and will proceed normally.
- **No automatic restore.** If the new revision or health check fails, the previous image is not restored automatically. A failed run does not guarantee the old version is back.
- **`containers[0]` only.** The workflow reads and compares the first container's image. Confirm every target app has a single container, or change the implementation to select the container by name.
- **Image-only rollback.** If the bad release also changed secrets or environment variables, rolling back the image may not restore a working app.
- **GitHub Environment location (verify on first run).** The reusable job declares `environment: ${{ inputs.environment }}`. This guide assumes the environment is resolved in the **caller (application) repository**, so `dev`, `qa` and `prod` must exist there. An earlier version of this guide said the environment belongs to the repository hosting the reusable workflow. That could not be verified; confirm with a dev run and adjust this section if the approval prompt appears on a different repository.

---

## 2. Placeholder and variable reference

### Caller workflow inputs

| Input | Required | Example | Meaning / validation |
|---|---|---|---|
| `app_name` | Yes | `qwest-users-dev` | Exact Container App name. Lowercase letters, digits and hyphens, max 32 characters, must start and end with a letter or digit. |
| `resource_group` | Yes | `qwest-dev-rg` | Resource group that contains the app. Letters, digits, `. _ - ( )`, max 90 characters. |
| `environment` | Yes | `dev` | One of `dev`, `qa`, `prod`. Selects the GitHub Environment used by the job. |
| `image_ref` | Yes | `<registry>/<repo>@sha256:<64-hex>` | Full immutable image reference. Never use `latest` or a mutable tag for rollback. |
| `smoke_test_url` | Yes | `https://<host>/<health-path>` | HTTPS health endpoint reachable from the runner. |

**Image-reference format:** `registry/repository@sha256:64_HEX_CHARACTERS`

Example format only (the registry, repository and digest are illustrative):

```text
mycompanyprod.azurecr.io/miq/frontend@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Get the real digest from the application's build/publish pipeline output or the ACR repository.

### Target values to verify before each new app/environment

| Value | Example | Where to verify |
|---|---|---|
| `app_name` | `qwest-users-dev` | Azure Portal → Container Apps, or `az containerapp list`. |
| `resource_group` | `qwest-dev-rg` | Azure Portal, or `az containerapp show`. Confirm subscription and environment. |
| `environment` | `dev` | Logical environment name. It is not automatically part of the Azure resource name. |
| `image_ref` | Full digest-pinned image | ACR image inventory / successful build run. |
| `smoke_test_url` | Verified HTTPS URL | Application owner or runbook. Must be reachable from the runner and test the rolled-back app. |

### Placeholders used in the caller workflow

| Placeholder | Meaning | Where to find it |
|---|---|---|
| `YOUR_ORG` | GitHub organization or owner | GitHub repository URL. |
| `qg-devops-workflows` | Central workflow repository | Actual repository name. |
| `YOUR_IMMUTABLE_COMMIT_SHA` | Full Git commit SHA of the reviewed reusable workflow | Commit history of the central repository. Prefer SHA pinning over a branch or movable tag. |
| `azure-private-network` | Runner label | Organization/repository → Settings → Actions → Runners. Must match a real runner label. |

**Do not assume example names are right for every environment.** Verify each target before first use.

---

## 3. GitHub Actions permissions

### 3.1 Workflow token permissions

The caller and reusable workflow use:

```yaml
permissions:
  contents: read
  id-token: write
```

- `contents: read`: permits repository content reads where needed. The workflow does not check out the repository, so it may not be needed by the reusable workflow itself; it is a safe, limited default.
- `id-token: write`: lets the job request an OIDC token. **It does not grant any Azure permission by itself**; Azure access is decided by the federated credential and Azure RBAC.
- Avoid `contents: write`, `actions: write`, `packages: write` or other broad token permissions.
- A called workflow cannot elevate permissions above what the caller grants.

### 3.2 Access to the private reusable-workflow repository

If `qg-devops-workflows` is private:

1. In the central repository, open **Settings → Actions → General**.
2. Find the access/policy section for reusable workflows.
3. Allow the intended application repositories or the appropriate organization scope.
4. In each caller repository, verify its Actions policy allows using the central repository's workflow.
5. Use a full commit SHA in `jobs.<job_id>.uses`, not `@main`.

```yaml
uses: YOUR_ORG/qg-devops-workflows/.github/workflows/rollback-container-app.yml@0123456789abcdef0123456789abcdef01234567
```

The SHA above is a placeholder, not a real revision.

### 3.3 GitHub Environments and approvals

Create the GitHub Environments `dev`, `qa` and `prod` in the **application repository** (see the verification note in section 1). Recommended protection:

- **`prod`:** Required reviewers / production approver group; prevent self-review where appropriate.
- Deployment branch/tag restrictions (for example only `main`).
- Environment-level auditability.
- Keep environment secrets/variables minimal.

Environment protection is an approval gate; it does not replace Azure RBAC.

**Secret behavior:** GitHub does not pass environment secrets from the caller through `workflow_call` automatically. The caller workflow uses `secrets: inherit` to hand its repository/organization secrets to the reusable workflow. Whether *environment-level* secrets also reach the reusable job has **not** been verified; test on dev (see section 6.1). If the reusable job references an environment holding a secret with the same name as a repository secret, the environment secret can take precedence. Avoid duplicate/conflicting secret names and document where each secret is set.

---

## 4. Azure identity and OIDC setup

### 4.1 Identity values

The workflow uses `azure/login@v2` with:

| GitHub secret | Value to store | Is it a password? |
|---|---|---|
| `AZURE_CLIENT_ID` | Application/client ID of the Microsoft Entra application or user-assigned managed identity used for workload federation | No |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID | No |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID | No |

These identifiers are not client secrets. **Do not create or store `AZURE_CLIENT_SECRET` for this OIDC design.**

### 4.2 Create or identify the Azure identity

Have an Azure administrator create or select the approved Microsoft Entra application / user-assigned managed identity for GitHub Actions, and record:

- Tenant ID, Client ID, Subscription ID
- Object/principal ID (needed for the Azure role assignment)
- Federated credential subject and issuer
- Approved resource scope

Do not paste IDs, tokens or credentials into chat, tickets or source code.

### 4.3 Federated credential

Create **one federated credential per repository and environment** in Microsoft Entra ID:

- **Issuer:** `https://token.actions.githubusercontent.com`
- **Audience:** `api://AzureADTokenExchange`
- **Subject:** for a job that references a GitHub Environment, commonly `repo:<org>/<repo>:environment:<env>` (for example `...:environment:dev`, `...:environment:qa`, `...:environment:prod`).

Do not guess the subject: confirm the claim from a real run's login error or the current GitHub/Azure OIDC guidance. A missing credential for an environment shows up as `AADSTS70025` (no federated credential configured). Avoid subjects that trust every branch or repository if a narrower one is practical.

Dev and qa may share one clientId/subscription, but each repository and environment still needs its own federated credential.

---

## 5. Azure RBAC permissions

### 5.1 Scope

Assign permissions at the smallest practical scope:

- Prefer the resource group that contains only the apps this identity may modify, or a custom role scoped to specific Container App resource IDs.
- Avoid `Owner` and `Contributor` at subscription scope.
- If several environments/resource groups are supported, assign each scope explicitly.
- The identity should not be able to modify networking, Key Vault, databases or unrelated infrastructure just to roll back an image.

Because the workflow is now generic, **the RBAC scope is the real limit on which apps can be rolled back.** Keep it tight, especially for production.

### 5.2 Recommended role strategy

**Preferred:** a custom role designed and reviewed for the exact CLI calls this workflow makes. At minimum the workflow needs to read the Container App and its revisions, and update the app's image. The CLI may make additional provider calls depending on its version. Test with the least-privilege role in a non-production resource group, inspect authorization failures, and add only the specific missing actions.

A built-in Container Apps role may be simpler, but review its full permissions first. Do not assume a role name means least privilege.

### 5.3 Illustrative custom-role definition

A starting point for review, not a guaranteed complete role for every CLI version:

```json
{
  "Name": "Container App Image Rollback Operator",
  "IsCustom": true,
  "Description": "Read Container App configuration and revisions; update the app image for rollback.",
  "Actions": [
    "Microsoft.App/containerApps/read",
    "Microsoft.App/containerApps/write",
    "Microsoft.App/containerApps/revisions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<TARGET_RESOURCE_GROUP>"
  ]
}
```

Replace `<SUBSCRIPTION_ID>` with the target subscription ID and `<TARGET_RESOURCE_GROUP>` with the resource group name (for example `qwest-dev-rg`).

- Validate that `Microsoft.App/containerApps/revisions/read` is accepted in your tenant. If Azure rejects it, inspect the provider operations and use the supported names. Some revision reads may be covered by `Microsoft.App/containerApps/read`.
- `Microsoft.App/containerApps/write` allows changes to more than the image. Approvals, branch restrictions and controlled workflow source are therefore critical.
- Do not include `Microsoft.Authorization/roleAssignments/write`, `Microsoft.Resources/deployments/write`, Key Vault secret reads or broad `*` permissions unless a documented requirement proves they are needed.

### 5.4 Image pull access is a separate identity

The GitHub deployment identity updates the Container App resource. The **Container App's own managed identity or registry credentials** pull the image from ACR. Before testing, verify that:

- The target app already has a working ACR registry configuration.
- Its identity has image-pull permission on that registry.
- The selected digest exists in the expected repository.
- If the app uses a user-assigned identity for ACR, it is attached to the app and configured for registry authentication.

Do not grant the GitHub deployment identity ACR push permission just to perform a rollback.

---

## 6. GitHub secrets and variables

### 6.1 Secrets to create

Add these names exactly. The caller uses `secrets: inherit`, so repository or organization secrets are passed to the reusable workflow automatically.

| Secret name | Value source | Required |
|---|---|---|
| `AZURE_CLIENT_ID` | Approved OIDC identity's client ID | Yes |
| `AZURE_TENANT_ID` | Entra tenant ID | Yes |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID | Yes |

Where to set them (in the **caller/application repository**):

- **Same values for all environments:** **Settings → Secrets and variables → Actions → Secrets → New repository secret.** Organization secrets scoped only to approved repositories are also valid.
- **Different values per environment (for example prod):** **Settings → Environments →** select `dev`, `qa` or `prod` **→ Environment secrets → Add environment secret.** Do not put prod values at organization level if dev/qa share different ones.

**Verify on first run (not yet tested):** that environment-level secrets reach the reusable job when the caller uses `secrets: inherit`. If `azure/login` reports a missing client ID, move the three secrets to repository level and re-run.

Do **not** create:

- `AZURE_CLIENT_SECRET` for this OIDC design.
- An ACR password if the Container App already authenticates to ACR using managed identity.
- A GitHub PAT just to call a reusable workflow in the same organization, unless your organization's access model requires it.

If the identity values must come from an environment manifest instead of secrets, see **section 13**.

### 6.2 Variables versus secrets

Use GitHub **Variables** for non-sensitive configuration only. The workflow does not read GitHub `vars`; adding a variable in Settings does nothing unless the YAML references `${{ vars.VARIABLE_NAME }}`.

---

## 7. Runner and network requirements

The reusable workflow requests:

```yaml
runs-on: [self-hosted, linux, azure-private-network]
```

Before the first run, verify that:

- A runner with **all three labels** exists and is online, and is available to the caller repository.
- The runner has a supported shell and `curl`.
- Azure CLI is installed and compatible with the Container Apps commands used.
- Outbound connectivity permits GitHub Actions job traffic and Entra/Azure login endpoints.
- The runner can reach the target app's health endpoint. Internal ingress normally requires a runner on the appropriate private network/DNS path.
- The runner host is maintained, patched, monitored and not shared with untrusted workloads. Self-hosted runners are not isolated merely because a GitHub Environment is used.

---

## 8. Before testing: verify Azure targets

Run these read-only commands from an approved terminal with an identity allowed to inspect the target subscription. Replace the values in the first lines with your real target (for example the subscription ID, `qwest-dev-rg`, `qwest-users-dev`).

```bash
SUB="<SUBSCRIPTION_ID>"
RG="<RESOURCE_GROUP>"
APP="<CONTAINER_APP_NAME>"

az login
az account set --subscription "$SUB"
az account show --output table

az containerapp list \
  --resource-group "$RG" \
  --query "[].{name:name,resourceGroup:resourceGroup,environment:managedEnvironmentId}" \
  --output table

az containerapp show \
  --name "$APP" \
  --resource-group "$RG" \
  --query "{name:name,resourceGroup:resourceGroup,latestRevision:properties.latestRevisionName,image:properties.template.containers[0].image,provisioningState:properties.provisioningState}" \
  --output json

az containerapp revision list \
  --name "$APP" \
  --resource-group "$RG" \
  --all \
  --output table
```

Confirm the selected subscription is the intended one before making changes. Avoid printing registry passwords or secrets into logs.

---

## 9. Test plan

Use a **dev** app first. Do not test on production just because it is the only configured option.

### Test 1 — YAML syntax and repository policy

1. Both files are under `.github/workflows/`.
2. The reusable workflow contains `on.workflow_call`.
3. The caller references the correct repository, path and immutable commit SHA.
4. Caller input names match the reusable workflow's declared inputs (`app_name`, `resource_group`, `environment`, `image_ref`, `smoke_test_url`).
5. The secret names match `on.workflow_call.secrets`, and the caller passes them (`secrets: inherit`).
6. The caller has `id-token: write`.
7. Actions policies allow the private reusable workflow.
8. Run a YAML linter / GitHub's workflow validation.

Expected: GitHub recognizes the workflow and the caller resolves the reusable workflow.

### Test 2 — Negative input tests

Run each in dev/non-production and expect a failure at **Validate inputs and resolve target**, with no Azure login or change:

- `environment` set to something other than `dev`/`qa`/`prod`.
- `app_name` with uppercase letters or an invalid format.
- `image_ref` without `@sha256:<64 hex>`.
- `smoke_test_url` that is not HTTPS.

### Test 3 — OIDC authentication

Run against a dev target. Expected: `Azure login using OIDC` succeeds and no client secret is requested. If it fails, check:

- `id-token: write` is granted.
- The three secrets exist and are correct, and reach the job (see the verify note in section 6.1).
- A federated credential exists for this repository **and** environment, with matching issuer, audience and subject.
- The identity exists in the expected tenant.

Do not print OIDC or access tokens in logs.

### Test 4 — Azure RBAC read test

Expected: `az containerapp show` succeeds and the workflow records the current image and revision. `AuthorizationFailed` means a role assignment or scope problem. A successful login proves authentication, not authorization.

### Test 5 — Image validation

Expected: a malformed image or a tag without a digest is rejected before any update. A digest from an unapproved registry is **not** rejected until registry allowlisting is implemented, so do not treat the regex as sufficient for production.

### Test 6 — Rollback and new-revision check (Fix 1)

1. Record the current image and revision.
2. Select a **different**, previously tested digest for the same app.
3. Run the caller workflow; approve the environment if required.
4. In the logs, expect "Waiting for a new revision ..." lines, then "New revision ... is running the requested image."
5. In Azure, confirm the latest revision uses the requested digest.

Expected: the step passes only after a revision different from the recorded one is `Provisioned`, `Running` and uses `image_ref`. If the step times out, its error prints the last revision seen, that revision's image and the requested image; compare them.

### Test 7 — Same-image run (Fix 2)

Run with the digest that is already deployed. Expected: the step **Record current image and revision** fails within seconds with "Already on this image ... No rollback performed." No update is made and no new revision appears in `az containerapp revision list`. The run summary still shows the previous image and revision.

### Test 8 — Health check

Run from the actual runner network. Expected: the HTTPS endpoint resolves, is reachable and returns a success status, and the URL tests the application itself. Verify each app's actual health path (`/health`, `/healthz`, `/healthcheck`, `/` and so on); do not assume they are the same.

### Test 9 — Failure-path tests (non-production only)

Digest that does not exist; health endpoint returning non-2xx; insufficient RBAC (use a dedicated test identity/resource group). Expected: failures are clear and visible. Check whether the app stays on the attempted image: **automatic restore is not implemented.**

### Test 10 — Verify the final state independently

```bash
az containerapp show \
  --name "$APP" \
  --resource-group "$RG" \
  --query "{latestRevision:properties.latestRevisionName,image:properties.template.containers[0].image}" \
  --output json

az containerapp revision list \
  --name "$APP" \
  --resource-group "$RG" \
  --all \
  --output table
```

Then call the health URL from the approved network and confirm application-level functionality.

### Test 11 — Production readiness review

- [ ] Prod `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are confirmed and set for the `prod` environment.
- [ ] Federated credential exists for the repository and the `prod` environment.
- [ ] RBAC role is least-privilege and scoped to the prod resource group(s).
- [ ] Registry/repository is allowlisted, not just digest-syntax-checked.
- [ ] Health URL is controlled, not freely typed by an operator.
- [ ] Failure restore behavior is implemented and tested.
- [ ] Same-image case (Fix 2) tested: running the already-deployed digest fails fast with "Already on this image".
- [ ] `prod` Environment has required reviewers and deployment-branch restriction.
- [ ] Reusable workflow is pinned to a reviewed immutable commit SHA.
- [ ] Runner labels, private DNS and endpoint connectivity are verified.
- [ ] Audit logs and run summaries are retained.
- [ ] A rollback operator and the application owner have agreed on the recovery procedure.
- [ ] Single container and single revision mode are confirmed for the target app.

---

## 10. Troubleshooting

| Symptom | Likely cause | Checks |
|---|---|---|
| Caller cannot find reusable workflow | Wrong owner/repo/path/SHA, or private workflow access not granted | Verify `uses:` and the Actions access policy on the central repo. |
| `azure/login` cannot get OIDC token | Missing `id-token: write` | Check caller and job permissions. |
| `azure/login` says client ID/tenant/subscription missing | Secret not set, misspelled, or an environment secret did not reach the reusable job | Check secret names exactly; try repository-level secrets. |
| `AADSTS70025` or other federation error | No federated credential for this repo/environment, or issuer/audience/subject/client mismatch | Compare the configured credential with the run's claims; create `...:environment:<env>` credential. |
| Login succeeds but app read fails | RBAC missing or wrong scope | Check principal/object ID, role assignment, subscription and resource group. |
| Container App update unauthorized | Missing Container App write permission | Review the exact failed operation and the custom role. |
| "Already on this image" error | The app already runs exactly the requested `image_ref` | Confirm the correct known-good digest was supplied; nothing was changed. |
| Stuck at "Waiting for a new revision" then timeout | The update did not create a revision (for example the image is the same but written differently, so the same-image check did not match) | Compare recorded revision/image with the requested digest; check `az containerapp revision list`. |
| Timeout with different "Last revision image" vs "Requested image" | Wrong digest/repository, image normalized differently by Azure, or another change replaced the revision | Compare the two printed images; inspect revision details. |
| Revision never becomes ready | App startup/probe failure or invalid image/config | Inspect revision details, logs, startup probes and app telemetry. |
| Image pull fails | Wrong digest/repository, digest unavailable, or app's ACR auth broken | Verify the digest and the app's own ACR identity/registry configuration. |
| Health check times out | Wrong URL/host/path, private DNS/network unavailable, TLS issue, or app unhealthy | Test from the same runner network and confirm the endpoint. |
| Environment approval not requested | Environment missing in the repository where the job resolves it, or wrong name | Check the caller repository's Environments first; see the verification note in section 1. |
| Run fails after deployment during health check | App did not pass the check; no automatic restore | Inspect the active revision and restore only through the approved recovery process. |

---

## 11. Operational safeguards

1. Restrict who can run the rollback workflow and who can approve production.
2. Pin the central reusable workflow to a reviewed commit SHA.
3. Because there is no allowlist, rely on a tightly scoped federated credential and RBAC role, and consider a reviewed allowlist for production.
4. Restrict deployment branches (at least `prod` to `main`) and protect `main`.
5. Validate registry/repository as well as digest syntax.
6. Control the health URL; do not curl arbitrary operator-supplied URLs from a private runner.
7. Do not echo secrets, tokens, connection strings or registry credentials.
8. Do not grant the GitHub identity broad subscription `Contributor` or `Owner` unless explicitly approved.
9. Keep rollback separate from Terraform apply/destroy. This workflow changes the Container App image only.
10. Confirm single vs multiple revision mode and how traffic is assigned. The workflow updates the image; it does not implement traffic shifting or revision labels.
11. An image-only rollback may not fix a release that also changed secrets or environment variables; check for that during incidents.
12. Record the image provenance, known-good digest, approver, run URL and post-rollback verification in the incident/change record.

---

## 12. Official references

- GitHub OIDC permission and token behavior: https://docs.github.com/en/actions/reference/security/oidc
- Configure OIDC in Azure: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure
- Reusable workflow access, inputs and secrets: https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows
- Reusable workflow configuration limitations and access policy: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
- GitHub deployment environments: https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- Azure CLI Container App revisions: https://learn.microsoft.com/en-us/cli/azure/containerapp/revision
- Azure role definitions and provider operations: https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions

---

## 13. Appendix: reading the Azure identity from the environment manifest (instead of GitHub secrets)

**Use this only if** the team decides that `clientId`, `tenantId` and `subscription` must come from the repository's environment manifest (`environments.<env>`) instead of the three GitHub secrets. The main design above does **not** need any of this. This appendix has not been run live.

The idea: check out the caller repository, read the three values for the selected environment with `jq`, and give them to `azure/login`. These IDs are not passwords, so reading them from a reviewed file is acceptable.

### 13.1 What changes, and where

| # | Where | Change |
|---|---|---|
| 1 | **Reusable workflow** → `on.workflow_call.inputs` | Add a new input `manifest_path` (snippet A). |
| 2 | **Reusable workflow** → `on.workflow_call.secrets` | **Remove** the whole `secrets:` block (the three `AZURE_*` secrets are no longer needed). |
| 3 | **Reusable workflow** → steps | Add two steps **after** "Validate inputs and resolve target" and **before** "Azure login using OIDC": a checkout step and a manifest-read step (snippet B). |
| 4 | **Reusable workflow** → "Azure login using OIDC" step | Replace the three `${{ secrets.AZURE_* }}` values with the manifest step outputs (snippet C). |
| 5 | **Caller workflow** → `jobs.rollback` | **Remove** `secrets: inherit`. Add `manifest_path` under `with:` (snippet D). |
| 6 | **Manifest file** (caller repo) | Must contain `clientId`, `tenantId`, `subscription` under `environments.<env>` for every environment you run (section 13.2). |
| 7 | **GitHub secrets** | The three `AZURE_*` secrets are not needed. Existing ones can stay unused or be removed later. |
| 8 | **Permissions** | `contents: read` is now required (it was optional), because the workflow checks out the repository. |
| 9 | **GitHub Environments** | Restrict **Deployment branches and tags** to `main` (see 13.3). |
| 10 | **Self-hosted runner** | `jq` and `git` must be installed (section 13.4). |

### 13.2 Snippets

**Snippet A — add to the reusable workflow's inputs**

```yaml
      manifest_path:
        description: "Path of env manifest JSON inside the caller repo (example: deploy/env-manifest.json)"
        required: true
        type: string
```

`deploy/env-manifest.json` is only an example. Use the manifest's real path in the caller repository.

**Snippet B — two new steps in the reusable workflow**

```yaml
      - name: Checkout caller repo (to read manifest)
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Read Azure identity from manifest
        id: manifest
        shell: bash
        env:
          MANIFEST_PATH: ${{ inputs.manifest_path }}
          TARGET_ENV: ${{ inputs.environment }}
        run: |
          set -euo pipefail

          command -v jq >/dev/null || { echo "::error::jq is required on the runner"; exit 1; }
          [[ -f "$MANIFEST_PATH" ]] || { echo "::error::manifest not found: $MANIFEST_PATH"; exit 1; }

          for KEY in clientId tenantId subscription; do
            VAL="$(jq -r --arg e "$TARGET_ENV" --arg k "$KEY" \
              '.environments[$e][$k] // empty' "$MANIFEST_PATH" | tr -d '\r')"
            if [[ -z "$VAL" || "$VAL" == REPLACE_* ]]; then
              echo "::error::environments.$TARGET_ENV.$KEY is missing or still a placeholder"
              exit 1
            fi
            echo "$KEY=$VAL" >> "$GITHUB_OUTPUT"
          done
```

This step fails on purpose when a value is missing or still starts with `REPLACE_`, so the workflow never attempts a login with a placeholder.

**Snippet C — replace the login step values**

```yaml
      - name: Azure login using OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ steps.manifest.outputs.clientId }}
          tenant-id: ${{ steps.manifest.outputs.tenantId }}
          subscription-id: ${{ steps.manifest.outputs.subscription }}
```

**Snippet D — caller workflow**

Delete `secrets: inherit`, and add under `with:`:

```yaml
      manifest_path: deploy/env-manifest.json
```

Use the real manifest path. If different apps use different paths, add `manifest_path` as a `workflow_dispatch` input instead of hardcoding it.

**Manifest keys the workflow reads**

```json
{
  "environments": {
    "dev": {
      "clientId": "<application/client ID of the OIDC identity>",
      "tenantId": "<Entra tenant ID>",
      "subscription": "<Azure subscription ID>"
    }
  }
}
```

- Keys must be exactly `clientId`, `tenantId`, `subscription` under `environments.<env>`.
- Do not put client secrets, tokens or keys in the manifest.
- Example: in the QWEST manifest the `prod` values are still `REPLACE_...` placeholders, so a prod run stops at the manifest step until they are confirmed.

### 13.3 New security consideration

The manifest is read from the branch the workflow runs on. An environment-based OIDC credential does not check the branch, so someone could run from a branch whose manifest names a different `clientId`. Reduce this risk by:

1. **Settings → Environments →** select the environment **→ Deployment branches and tags →** allow only `main` (at minimum for `prod`).
2. Protecting `main` with branch protection and required reviews.
3. Reviewing any manifest change to `clientId`, `tenantId` or `subscription` like a security change.

### 13.4 Runner additions

On the self-hosted runner, check:

```bash
jq --version
git --version
```

Expected: both print a version. If `jq` is missing, install it on the runner host/image before the first run.

### 13.5 What does not change

- The federated credential is still needed for each repository and environment (section 4.3).
- Azure RBAC scope and role (section 5).
- GitHub Environments and approvals (section 3.3).
- Revision wait, health check and summary steps.

### 13.6 Extra tests and troubleshooting for this option

| Check / symptom | Cause | Action |
|---|---|---|
| "manifest not found" | Wrong `manifest_path`, or file not on the branch being run | Confirm the path and branch. |
| "environments.<env>.<key> is missing or still a placeholder" | Manifest incomplete (for example QWEST prod) | Get the real values confirmed and update the manifest through review. |
| "jq is required on the runner" | `jq` not installed on the runner | Install `jq` on the runner. |

Test: run dev and confirm both **Read Azure identity from manifest** and **Azure login using OIDC** are green; run an environment with `REPLACE_...` values and confirm it fails at the manifest step, before login.