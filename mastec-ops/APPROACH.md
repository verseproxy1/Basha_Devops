# Shared GitHub Reusable Workflows - Approach

As of 2026-10-28. Owner: QWEST platform team. Task status is in `WORK_TRACKER.md`.

## Purpose

Today the build, deploy and rollback logic is copied into each service repo, and the copies have drifted apart. This plan moves that logic into one shared repo, `Mastec-Quadgen-AzureApps/mastec-ops`. Each service repo keeps only its Dockerfiles, a manifest, and a short caller file. A fix made once reaches every service.

## 1. Architecture

```
┌──────────────── GitHub org: Mastec-Quadgen-AzureApps ────────────────┐
│                                                                      │
│   mastec-ops  (written once, reviewed by pull request)               │
│   ├─ build-push-acr          build image, push to the env's ACR      │
│   ├─ deploy-container-apps   apply every container, check health     │
│   ├─ rollback-container-app  restore a service to known-good digests │
│   ├─ rbac-setup              one-time, manual, grants access         │
│   └─ secret-scan             gitleaks with the central config        │
│                 ▲ uses:                ▲ uses:                       │
│   ┌─────────────┴────────┐   ┌────────┴───────────┐                  │
│   │ qwest_users          │   │ qwest_requests ... │  (each repo:     │
│   │  Dockerfile(s)       │   │                    │   Dockerfiles,   │
│   │  manifest.json       │   │                    │   manifest,      │
│   │  caller workflow     │   │                    │   short caller)  │
│   └──────────────────────┘   └────────────────────┘                  │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │ OIDC login: one credential per
                                    │ repo and environment
┌───────────────────────────────────▼──────────────────────────────────┐
│ Azure, per environment (dev / qa / prod)                             │
│   ACR  ·  resource group with Container Apps  ·  Key Vault           │
└──────────────────────────────────────────────────────────────────────┘
Runner: nprd-git-runner-001 (self-hosted, Linux, x64, private network, Docker)
```

| Location | Holds | Changes how often |
|---|---|---|
| mastec-ops | Reusable workflows and scripts. No secret values. | Through reviewed pull requests |
| Service repo | Dockerfiles, manifest, short caller | When the service changes |
| Manifest | Per service: Dockerfile, ACR repo, container list, resources, scaling, Key Vault secret names | Per service |
| GitHub Environments | `dev`, `qa`, `prod` in each repo, with their secrets and approval rules | Set once per repo |
| Key Vault | Secret values | Outside the repos |

## 2. Repo layout of mastec-ops

```
mastec-ops/
├─ .github/workflows/
│  ├─ build-push-acr.yml            reusable, written (untested)
│  ├─ deploy-container-apps.yml     reusable, written (untested)
│  ├─ rollback-container-app.yaml   reusable, written; container loop still to do
│  ├─ rbac-setup.yml                reusable, manual, written (untested)
│  ├─ secret-scan.yml               reusable, written (untested)
│  └─ rollback.yml                  caller, used to test this repo
├─ scripts/                         generate-container-config, pre-deploy-checks, setup-kv-rbac (written, from users)
├─ gitleaks/                        .gitleaks.toml, central config (written)
├─ APPROACH.md
└─ WORK_TRACKER.md
```

Explanation: the `.yml` files under `workflows/` marked "reusable" can only be called by other repos with `uses:`. They don't run on their own. Scripts sit beside them so every caller uses the same copy.

## 3. Service repo: the caller and the manifest

```
service repo (e.g. qwest_users)
   │
   ├─ Dockerfile                       web image
   ├─ qwest-users-env-manifest.json    what to build, where to deploy, secret names
   └─ .github/workflows/ci-cd.yml      short caller: environment + manifest path
          │
          │ uses: Mastec-Quadgen-AzureApps/mastec-ops/.github/workflows/...@<ref>
          ▼
   mastec-ops reusable workflows run with this repo's values
```

Explanation: the caller says *what* to deploy (service and environment). The manifest says *how* (images, containers, scaling, secret names). The shared workflow contains no service-specific values, so the same code serves every repo.

## 4. Build: build-push-acr

```
start (environment = dev)
   │
read manifest ── for each service in services[]:
   │               docker build  (its Dockerfile)
   │               push to ACR:  <run-id> tag and latest
   ▼
output: image digest per service
```

Explanation: every image gets an immutable run-ID tag. `latest` is kept for convenience only. The digest, not the tag, is what rollback uses.

## 5. Deploy: deploy-container-apps

```
image digests (from build)
   │
pre-deploy checks  (apps exist, identity present, access granted)
   │
for each container in service.containerApps:          ← web, worker, beat
   │    generate config  (secrets as Key Vault references, image digest)
   │    az containerapp update --yaml
   ▼
poll every container:  Running and Healthy?
   │
   ├─ no  → stop, name the container that failed
   └─ yes → done
```

Explanation: the deploy loops over the list in the manifest, so one service with three containers is one job. Beat's manifest entry fixes `maxReplicas: 1`, because two copies of beat would run every scheduled job twice. Secrets are read by the container from Key Vault. They never appear in the workflow.

## 6. Rollback: rollback-container-app

```
manual trigger: service, environment, digest per container, health URL
   │
validate inputs   (digest format, HTTPS URL, valid names)
   │
Azure login (OIDC)
   │
for each container:  single-revision mode?  ── no → stop
   │ yes
record current image and revision
   │
set each container to its known-good digest
   │
wait for a new revision running that digest
   │
health check (retries)
   │
summary on the run page
```

Explanation: rollback is for recovery, not a step in every deploy. It restores all containers of the service together, so web and worker stay on matching versions. The single-revision check stops the job when Azure wouldn't move traffic to the restored revision. A revision is a saved snapshot of an app's full setup (image, environment variables, scaling).

Status: the input checks, login, single-revision check, update, wait and summary are written. The loop over a service's containers is not written yet.

## 7. Secret scan: secret-scan

```
push or pull request in a service repo
   │
secret-scan (in mastec-ops), gitleaks with the central config
   │
secret found? ── yes → check fails → branch ruleset blocks the merge
   │ no
pass
```

Explanation: scanning runs on the server, so it can't be skipped by a developer who hasn't installed the local hook. The organization ruleset requires it to pass on protected branches. Repo-specific allowlists are merged into the central config, so each repo doesn't keep its own.

## 8. Login and secrets

```
job in repo qwest_users, environment dev
   │ presents OIDC token with subject:
   │   repo:Mastec-Quadgen-AzureApps/qwest_users:environment:dev
   ▼
Entra ID: is there a federated credential for this exact subject?
   │
   ├─ no  → login fails (nothing is granted)
   └─ yes → Azure token
              │
              ▼
        ACR push, Container Apps update, Key Vault read through the app identity
```

Explanation:
- **OIDC, no client secret.** GitHub proves who is calling, and Azure trusts that proof only for the matching federated credential.
- **One credential per repo and environment (decided).** Each login traces to one repo and one environment. A wildcard would let any matching repo log in as the same identity, so it is not used.
- **No secret values in repos or images.** Secret values live in Key Vault. The manifest holds only their names.

## 9. Environments: dev → qa → prod

```
dev  ──────────►  qa  ──────────────────►  prod
no approval       one reviewer             named reviewers + wait timer
  │                 │                        │
  └──── same shared workflow, only the environment input changes ────┘
```

| Environment | Started by | Approval | Registry | Resource group |
|---|---|---|---|---|
| dev | Developer | None | qwestdevacr1 | qwest-dev-rg |
| qa | Developer | One reviewer | qwestqaacr1 | qwest-qa-rg |
| prod | Release owner | Named reviewers, wait timer | qwestprodacr1 | qwest-prod-rg |

Explanation: the approval rules belong in each repo's GitHub Environments, not in mastec-ops. The legacy Azure DevOps pipelines still push to `qwestnprdacr01` and `qwestprodacr01` until they are retired.

Pinning:
- **Prod callers** are pinned to a full 40-character commit SHA. A tag or `main` can move without review.
- **Dev and QA callers** may use a version tag such as `@v1`.

## 10. Sidecar containers

```
service qwest_requests (one service entry, a containerApps list)
   │
   ├─ web      Django / Daphne        1 to 3 replicas
   ├─ worker   Celery worker          1 to 3 replicas
   └─ beat     Celery scheduler       exactly 1 replica
   │
deploy: all three together      rollback: all three together

service qwest_users (one container)
   └─ web + worker + beat run inside one container
```

Explanation:
- **Worker** runs background jobs, such as emails and long reports.
- **Beat** adds scheduled jobs to the queue. It must run as one copy, or every scheduled job runs twice.
- **Why this matters:** if the deploy updated only the web container, the worker could stay on an old version, and background jobs could fail without any error on the web side.

Coverage to check: requests and tickets use web, worker and beat. Users uses one container. Reporting may have a worker, and needs checking.

## 11. Rollout

```
Phase 1  Shared repo builds and runs locally
   │  gate: workflows pass a syntax check
Phase 2  Secret-scan pilot in one repo
   │  gate: same results as the old scan
Phase 3  Deploy pilot: qwest_ssh_service_forwarder, dev only
   │  gate: image deployed, health check passed
Phase 4  Pilot to qa and prod
   │  gate: successful prod deploy
Phase 5  Migrate the other repos one at a time
   │  each: caller added, one dev deploy, then qa, then prod
Phase 6  Delete old copies in each repo
      gate: one successful prod deploy since migration
```

Explanation: each phase is a small step with a clear pass condition. If a phase fails, only that repo is affected, and the old workflow file is still in git, so it can be restored.

Dev test checklist (rollback and secrets):
1. Set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` on the `dev` environment of the calling repo. Remove repo-level copies with the same names.
2. Run Rollback Container App from GitHub, with `dev`, a dev app, its resource group, a digest-pinned image, and its health URL.
3. If Azure login succeeds, environment secrets reach the job. If it fails with an empty client ID, move the secrets to repository level and run again.
4. Check the run summary for previous image, previous revision, requested image and result.

## 12. Decisions made

| Topic | Decision |
|---|---|
| Repo name | `mastec-ops` |
| OIDC | One federated credential per repo and environment |
| Sidecars | One service entry with a `containerApps` list |
| Rollback | Manual only, restores a service as a set |
| Prod pinning | Full commit SHA |
| Dev and QA pinning | Version tag allowed |
| Pipelines | One pipeline may deploy a given repo and branch at a time |
| Runner | `nprd-git-runner-001`, labels `self-hosted, linux, x64` |
| Migration | Proof of concept on GitHub, not Azure DevOps; migration runs in the same flow |
| Secrets | In Key Vault only; repos hold manifests with names |
| Gmail SMTP | Replace with Office 365 SMTP; list dependent apps with their URL and container name |
| Docs | Approach doc committed as HTML in the docs folder once the team agrees |

## 13. Open items

1. **`secrets: inherit`:** does it pass environment-level secrets to a reusable job? Test on dev (section 11).
2. **Pilot repo:** confirm `qwest_ssh_service_forwarder` is migrated. The review doc and the meeting disagree.
3. **Runner Docker:** confirm `nprd-git-runner-001` has Docker, which the build and deploy need.
4. **Prod approvers:** name the reviewers for each repo's `prod` environment.
5. **Repo split:** which repos are on GitHub only, and which are still Azure DevOps only.

Also needed, not a question: the Dockerfiles must use BuildKit secrets for the private pip feed, so the token isn't stored in the repo or a build argument.

## 14. Next steps

1. Send a dev test target: app name, resource group, and health URL.
2. Write `build-push-acr` and `deploy-container-apps`, based on the users repo, with the container loop.
3. Add the container loop to the rollback workflow.
4. Resolve the differences between the three helper scripts in users and requests, and move them to mastec-ops.
5. Run the dev test checklist.
6. Pilot, then migrate the other repos as in section 11.
7. Decide when the ADO pipelines are retired.
