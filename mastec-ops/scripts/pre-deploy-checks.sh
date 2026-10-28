#!/usr/bin/env bash
#
# pre-deploy-checks.sh
#
# Pre-deploy gate, run before any Container App is changed. For each container
# app of the service it checks (via the Azure management API) that:
#   - the app exists and has a SystemAssigned managed identity,
#   - that identity holds AcrPull on the registry,
#   - that identity holds Key Vault Secrets User on the vault.
# A failure means the one-time RBAC setup (rbac-setup workflow) has not been run
# for this environment.
#
# It also runs an advisory check that each Key Vault secret named in the manifest
# exists. That check only warns and never fails the gate.
#
# Shared script: lives in mastec-ops, run from the caller repo root with
# MANIFEST_PATH set to the caller's manifest.
#
# Usage (from the caller repo root):
#   MANIFEST_PATH=<manifest.json> bash shared/scripts/pre-deploy-checks.sh \
#     <dev|qa|prod> <service> [--skip-kv-check]
#
# --skip-kv-check: skips the advisory Key Vault secret check. Use it only while
# the CI identity has no Key Vault data-plane role, because without that role
# every secret shows as missing whether or not it exists.
#
# Exit codes:
#   0 - all ARM checks passed (the advisory secret check never changes this)
#   1 - invalid arguments, manifest problem, or one or more ARM checks failed
#
set -euo pipefail

MANIFEST="${MANIFEST_PATH:?MANIFEST_PATH must be set by the calling workflow}"

usage() {
  echo "Usage: $0 <dev|qa|prod> <service> [--skip-kv-check]" >&2
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

ENV_NAME="$1"
SERVICE="$2"
shift 2

SKIP_KV_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-kv-check) SKIP_KV_CHECK=1; shift ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

case "$ENV_NAME" in
  dev|qa|prod) ;;
  *)
    echo "ERROR: environment must be one of dev, qa, prod (got: '$ENV_NAME')" >&2
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: az CLI is required but not found in PATH." >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest file not found: $MANIFEST" >&2
  exit 1
fi

if ! jq -e --arg s "$SERVICE" '.services | has($s)' "$MANIFEST" >/dev/null 2>&1; then
  echo "::error::service '$SERVICE' not found in manifest (.services)"
  exit 1
fi

RESOURCE_GROUP=$(jq -r --arg e "$ENV_NAME" '.environments[$e].resourceGroup // empty' "$MANIFEST" | tr -d '\r')
if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "::error::environments.$ENV_NAME.resourceGroup is missing in manifest"
  exit 1
fi

# Resource IDs are needed so the role checks can pass an explicit --scope.
# Without --scope, `az role assignment list` searches only the subscription
# root and can report a grant as missing when it exists on the resource.
ACR_NAME=$(jq -r --arg e "$ENV_NAME" '.environments[$e].acr // empty' "$MANIFEST" | tr -d '\r')
VAULT_NAME=$(jq -r --arg e "$ENV_NAME" '.environments[$e].vault // empty' "$MANIFEST" | tr -d '\r')

if [[ -z "$ACR_NAME" ]]; then
  echo "::error::environments.$ENV_NAME.acr is missing in manifest"
  exit 1
fi
if [[ -z "$VAULT_NAME" ]]; then
  echo "::error::environments.$ENV_NAME.vault is missing in manifest"
  exit 1
fi

if ! ACR_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv); then
  echo "::error::Failed to resolve resource ID for ACR '$ACR_NAME' in resource group '$RESOURCE_GROUP'"
  exit 1
fi
ACR_ID=$(printf '%s' "$ACR_ID" | tr -d '\r')

if ! KV_ID=$(az keyvault show --name "$VAULT_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv); then
  echo "::error::Failed to resolve resource ID for Key Vault '$VAULT_NAME' in resource group '$RESOURCE_GROUP'"
  exit 1
fi
KV_ID=$(printf '%s' "$KV_ID" | tr -d '\r')

CONTAINER_APP_TEMPLATES=$(jq -r --arg s "$SERVICE" '.services[$s].containerApps[]? // empty' "$MANIFEST" | tr -d '\r')

if [[ -z "$CONTAINER_APP_TEMPLATES" ]]; then
  echo "::error::services.$SERVICE.containerApps is empty in manifest"
  exit 1
fi

echo "----------------------------------------"
echo "ARM checks (Container Apps, identity, RBAC)"
echo "----------------------------------------"
echo "Environment:    $ENV_NAME"
echo "Service:        $SERVICE"
echo "Resource group: $RESOURCE_GROUP"
echo ""

TOTAL_APPS=0
PASSED_APPS=0
FAILED_APPS=0

# Process substitution (not a pipe) keeps the counters in this shell. A piped
# `while read` would run in a subshell and lose them.
while IFS= read -r template; do
  [[ -z "$template" ]] && continue

  APP_NAME="${template/\{env\}/$ENV_NAME}"
  TOTAL_APPS=$((TOTAL_APPS + 1))
  APP_FAILED=0

  echo "Checking container app: $APP_NAME"

  if ! SHOW_JSON=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" -o json); then
    echo "::error::Container App $APP_NAME not found or az CLI not authenticated"
    FAILED_APPS=$((FAILED_APPS + 1))
    continue
  fi

  IDENTITY_TYPE=$(echo "$SHOW_JSON" | jq -r '.identity.type // empty' 2>/dev/null | tr -d '\r')
  if [[ "$IDENTITY_TYPE" != *"SystemAssigned"* ]]; then
    echo "::error::Container App $APP_NAME does not have a SystemAssigned managed identity (found: '$IDENTITY_TYPE'). Run the rbac-setup workflow for $ENV_NAME first."
    APP_FAILED=1
  fi

  PRINCIPAL_ID=$(echo "$SHOW_JSON" | jq -r '.identity.principalId // empty' 2>/dev/null | tr -d '\r')
  if [[ -z "$PRINCIPAL_ID" || "$PRINCIPAL_ID" == "null" ]]; then
    echo "::error::Container App $APP_NAME has no identity.principalId (managed identity not provisioned)"
    APP_FAILED=1
  else
    if ! ACR_ASSIGNMENTS=$(az role assignment list --assignee "$PRINCIPAL_ID" --role "AcrPull" --scope "$ACR_ID" -o json); then
      echo "::error::Failed to query AcrPull role assignments for $APP_NAME (az CLI not authenticated?)"
      APP_FAILED=1
    else
      ACR_COUNT=$(echo "$ACR_ASSIGNMENTS" | jq -r 'length' 2>/dev/null | tr -d '\r')
      if [[ -z "$ACR_COUNT" || "$ACR_COUNT" == "0" ]]; then
        echo "::error::Container App $APP_NAME's managed identity is missing the AcrPull role assignment. Run the rbac-setup workflow for $ENV_NAME."
        APP_FAILED=1
      fi
    fi

    if ! KV_ASSIGNMENTS=$(az role assignment list --assignee "$PRINCIPAL_ID" --role "Key Vault Secrets User" --scope "$KV_ID" -o json); then
      echo "::error::Failed to query Key Vault Secrets User role assignments for $APP_NAME (az CLI not authenticated?)"
      APP_FAILED=1
    else
      KV_COUNT=$(echo "$KV_ASSIGNMENTS" | jq -r 'length' 2>/dev/null | tr -d '\r')
      if [[ -z "$KV_COUNT" || "$KV_COUNT" == "0" ]]; then
        echo "::error::Container App $APP_NAME's managed identity is missing the Key Vault Secrets User role assignment. Run the rbac-setup workflow for $ENV_NAME."
        APP_FAILED=1
      fi
    fi
  fi

  if [[ "$APP_FAILED" -eq 1 ]]; then
    FAILED_APPS=$((FAILED_APPS + 1))
  else
    PASSED_APPS=$((PASSED_APPS + 1))
    echo "[OK] $APP_NAME passed all ARM checks"
  fi
  echo ""
done < <(echo "$CONTAINER_APP_TEMPLATES")

echo "----------------------------------------"
echo "Advisory: Key Vault secret existence"
echo "----------------------------------------"

MISSING=0
if [[ "$SKIP_KV_CHECK" -eq 1 ]]; then
  echo "Skipped (--skip-kv-check passed) -- assuming secrets are present."
else
  VAR_NAMES=$(jq -r --arg s "$SERVICE" '.services[$s].vars | keys[]?' "$MANIFEST" | tr -d '\r')
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    kv_name=$(jq -r --arg s "$SERVICE" --arg v "$var" --arg e "$ENV_NAME" '.services[$s].vars[$v][$e] // empty' "$MANIFEST" | tr -d '\r')
    [[ -z "$kv_name" ]] && continue

    if az keyvault secret show --vault-name "$VAULT_NAME" --name "$kv_name" --output none 2>/dev/null; then
      echo "  OK   $var -> $kv_name"
    else
      echo "::warning::Key Vault secret '$kv_name' (for $var) not found in $VAULT_NAME"
      MISSING=$((MISSING + 1))
    fi
  done <<< "$VAR_NAMES"
fi

if [[ "$MISSING" -gt 0 ]]; then
  echo ""
  echo "::warning::$MISSING expected Key Vault secret(s) missing. Advisory only, not failing the gate."
fi
echo ""

echo "----------------------------------------"
echo "Summary"
echo "----------------------------------------"
echo "Container apps checked: $TOTAL_APPS"
echo "  Passed: $PASSED_APPS"
echo "  Failed: $FAILED_APPS"

if [[ "$FAILED_APPS" -gt 0 ]]; then
  echo ""
  echo "RESULT: FAILED"
  exit 1
fi

echo ""
echo "RESULT: PASSED"
exit 0
