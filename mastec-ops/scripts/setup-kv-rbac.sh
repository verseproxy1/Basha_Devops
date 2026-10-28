#!/usr/bin/env bash
#
# setup-kv-rbac.sh
#
# ONE-TIME setup, run by the manual rbac-setup workflow, not by the normal
# deploy. It makes sure every container app in the caller's manifest has:
#   - a SystemAssigned managed identity,
#   - AcrPull on the environment's ACR,
#   - Key Vault Secrets User on the environment's Key Vault.
# pre-deploy-checks.sh verifies these before each deploy.
#
# It runs with a higher-privilege identity (the self-hosted runner VM's managed
# identity) than the deploy workflow's OIDC login, so it is kept separate and
# is never run as part of a normal deploy.
#
# Idempotent: re-running it skips anything already in place. Run it again when a
# new container app is added to the manifest.
#
# Shared script: lives in mastec-ops, run from the caller repo root with
# MANIFEST_PATH set to the caller's manifest.
#
# Usage (from the caller repo root):
#   MANIFEST_PATH=<manifest.json> bash shared/scripts/setup-kv-rbac.sh <dev|qa|prod> [--dry-run]
#
# Exit codes:
#   0 - dry run finished, or every container app is fully configured
#   1 - invalid arguments, manifest problem, az CLI not logged in, or one or
#       more container apps did not reach the fully configured state
#
set -euo pipefail

MANIFEST="${MANIFEST_PATH:?MANIFEST_PATH must be set by the calling workflow}"

usage() {
  echo "Usage: $0 <dev|qa|prod> [--dry-run]" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

ENV_NAME="$1"
shift

DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
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

# Stop before looping over apps if az is not logged in.
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: az CLI is not logged in. Run 'az login' (or the management identity login) first." >&2
  exit 1
fi

RESOURCE_GROUP=$(jq -r --arg e "$ENV_NAME" '.environments[$e].resourceGroup // empty' "$MANIFEST" | tr -d '\r')
ACR=$(jq -r --arg e "$ENV_NAME" '.environments[$e].acr // empty' "$MANIFEST" | tr -d '\r')
VAULT=$(jq -r --arg e "$ENV_NAME" '.environments[$e].vault // empty' "$MANIFEST" | tr -d '\r')

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "ERROR: environments.$ENV_NAME.resourceGroup is missing in manifest" >&2
  exit 1
fi
if [[ -z "$ACR" ]]; then
  echo "ERROR: environments.$ENV_NAME.acr is missing in manifest" >&2
  exit 1
fi
if [[ -z "$VAULT" ]]; then
  echo "ERROR: environments.$ENV_NAME.vault is missing in manifest" >&2
  exit 1
fi

# Container apps across every service in the manifest. A caller with several
# services gets all of them set up in one run.
CONTAINER_APP_TEMPLATES=$(jq -r '.services[] | .containerApps[]? // empty' "$MANIFEST" | tr -d '\r')

if [[ -z "$CONTAINER_APP_TEMPLATES" ]]; then
  echo "ERROR: no containerApps found anywhere in manifest .services" >&2
  exit 1
fi

APP_NAMES=()
while IFS= read -r template; do
  [[ -z "$template" ]] && continue
  APP_NAMES+=("${template/\{env\}/$ENV_NAME}")
done <<< "$CONTAINER_APP_TEMPLATES"

echo "----------------------------------------"
echo "setup-kv-rbac: $ENV_NAME"
echo "----------------------------------------"
echo "Resource group: $RESOURCE_GROUP"
echo "ACR:            $ACR"
echo "Key Vault:      $VAULT"
echo "Container apps: ${#APP_NAMES[@]}"
for a in "${APP_NAMES[@]}"; do
  echo "  - $a"
done
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Mode:           DRY RUN (no changes will be made)"
else
  echo "Mode:           LIVE"
fi
echo ""

echo "----------------------------------------"
echo "Resolving resource IDs"
echo "----------------------------------------"

if ! ACR_ID_RAW=$(az acr show --name "$ACR" --resource-group "$RESOURCE_GROUP" --query id -o tsv); then
  echo "::error::Failed to resolve resource ID for ACR '$ACR' in resource group '$RESOURCE_GROUP'" >&2
  exit 1
fi
ACR_ID=$(printf '%s' "$ACR_ID_RAW" | tr -d '\r')
echo "ACR resource ID:       $ACR_ID"

if ! KV_ID_RAW=$(az keyvault show --name "$VAULT" --resource-group "$RESOURCE_GROUP" --query id -o tsv); then
  echo "::error::Failed to resolve resource ID for Key Vault '$VAULT' in resource group '$RESOURCE_GROUP'" >&2
  exit 1
fi
KV_ID=$(printf '%s' "$KV_ID_RAW" | tr -d '\r')
echo "Key Vault resource ID: $KV_ID"
echo ""

echo "----------------------------------------"
echo "Managed identity + RBAC per container app"
echo "----------------------------------------"

APP_IDENTITY_STATUS=()
APP_ACR_STATUS=()
APP_KV_STATUS=()

OVERALL_FAILED=0

for APP_NAME in "${APP_NAMES[@]}"; do
  echo ""
  echo "Container app: $APP_NAME"

  PRINCIPAL_ID=""

  if ! SHOW_JSON=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" -o json); then
    echo "::error::Container App $APP_NAME not found (or az CLI error) in resource group $RESOURCE_GROUP"
    APP_IDENTITY_STATUS+=("NOT FOUND")
    APP_ACR_STATUS+=("SKIPPED")
    APP_KV_STATUS+=("SKIPPED")
    OVERALL_FAILED=1
    continue
  fi

  IDENTITY_TYPE=$(echo "$SHOW_JSON" | jq -r '.identity.type // empty' 2>/dev/null | tr -d '\r')
  PRINCIPAL_ID=$(echo "$SHOW_JSON" | jq -r '.identity.principalId // empty' 2>/dev/null | tr -d '\r')

  if [[ "$IDENTITY_TYPE" == *"SystemAssigned"* && -n "$PRINCIPAL_ID" && "$PRINCIPAL_ID" != "null" ]]; then
    echo "  Managed identity: already enabled (principalId=$PRINCIPAL_ID)"
    APP_IDENTITY_STATUS+=("ENABLED")
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  Managed identity: NOT enabled. [DRY RUN] would run: az containerapp identity assign --name $APP_NAME --resource-group $RESOURCE_GROUP --system-assigned"
    APP_IDENTITY_STATUS+=("DRY-RUN-PENDING")
    PRINCIPAL_ID=""
  else
    echo "  Managed identity: not enabled. Assigning SystemAssigned identity..."
    if ! ASSIGN_JSON=$(az containerapp identity assign --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --system-assigned -o json); then
      echo "::error::Failed to assign SystemAssigned identity to $APP_NAME"
      APP_IDENTITY_STATUS+=("FAILED")
      APP_ACR_STATUS+=("SKIPPED")
      APP_KV_STATUS+=("SKIPPED")
      OVERALL_FAILED=1
      continue
    fi
    PRINCIPAL_ID=$(echo "$ASSIGN_JSON" | jq -r '.principalId // empty' 2>/dev/null | tr -d '\r')
    if [[ -z "$PRINCIPAL_ID" || "$PRINCIPAL_ID" == "null" ]]; then
      echo "::error::Identity assign for $APP_NAME succeeded but no principalId was returned"
      APP_IDENTITY_STATUS+=("FAILED")
      APP_ACR_STATUS+=("SKIPPED")
      APP_KV_STATUS+=("SKIPPED")
      OVERALL_FAILED=1
      continue
    fi
    echo "  Managed identity: enabled (principalId=$PRINCIPAL_ID)"
    APP_IDENTITY_STATUS+=("ENABLED")
  fi

  if [[ -z "$PRINCIPAL_ID" ]]; then
    echo "  AcrPull role:     [DRY RUN] no principalId yet. Would grant AcrPull once identity is enabled."
    echo "  KV Secrets role:  [DRY RUN] no principalId yet. Would grant Key Vault Secrets User once identity is enabled."
    APP_ACR_STATUS+=("DRY-RUN-PENDING")
    APP_KV_STATUS+=("DRY-RUN-PENDING")
    continue
  fi

  # AcrPull on the registry.
  if ! ACR_ASSIGNMENTS=$(az role assignment list --assignee "$PRINCIPAL_ID" --role "AcrPull" --scope "$ACR_ID" -o json); then
    echo "::error::Failed to query AcrPull role assignments for $APP_NAME"
    APP_ACR_STATUS+=("UNKNOWN")
    OVERALL_FAILED=1
  else
    ACR_COUNT=$(echo "$ACR_ASSIGNMENTS" | jq -r 'length' 2>/dev/null | tr -d '\r')
    if [[ -n "$ACR_COUNT" && "$ACR_COUNT" != "0" ]]; then
      echo "  AcrPull role:     already granted"
      APP_ACR_STATUS+=("GRANTED")
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  AcrPull role:     [DRY RUN] would run: az role assignment create --assignee $PRINCIPAL_ID --role AcrPull --scope $ACR_ID"
      APP_ACR_STATUS+=("DRY-RUN-PENDING")
    else
      echo "  AcrPull role:     not granted. Creating role assignment..."
      if CREATE_ERR=$(az role assignment create --assignee "$PRINCIPAL_ID" --role "AcrPull" --scope "$ACR_ID" 2>&1 1>/dev/null); then
        echo "  AcrPull role:     granted"
        APP_ACR_STATUS+=("GRANTED")
      else
        echo "::error::Failed to grant AcrPull role to $APP_NAME"
        echo "$CREATE_ERR" >&2
        APP_ACR_STATUS+=("FAILED")
        OVERALL_FAILED=1
      fi
    fi
  fi

  # Key Vault Secrets User on the vault.
  if ! KV_ASSIGNMENTS=$(az role assignment list --assignee "$PRINCIPAL_ID" --role "Key Vault Secrets User" --scope "$KV_ID" -o json); then
    echo "::error::Failed to query Key Vault Secrets User role assignments for $APP_NAME"
    APP_KV_STATUS+=("UNKNOWN")
    OVERALL_FAILED=1
  else
    KV_COUNT=$(echo "$KV_ASSIGNMENTS" | jq -r 'length' 2>/dev/null | tr -d '\r')
    if [[ -n "$KV_COUNT" && "$KV_COUNT" != "0" ]]; then
      echo "  KV Secrets role:  already granted"
      APP_KV_STATUS+=("GRANTED")
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  KV Secrets role:  [DRY RUN] would run: az role assignment create --assignee $PRINCIPAL_ID --role \"Key Vault Secrets User\" --scope $KV_ID"
      APP_KV_STATUS+=("DRY-RUN-PENDING")
    else
      echo "  KV Secrets role:  not granted. Creating role assignment..."
      if CREATE_ERR=$(az role assignment create --assignee "$PRINCIPAL_ID" --role "Key Vault Secrets User" --scope "$KV_ID" 2>&1 1>/dev/null); then
        echo "  KV Secrets role:  granted"
        APP_KV_STATUS+=("GRANTED")
      else
        echo "::error::Failed to grant Key Vault Secrets User role to $APP_NAME"
        echo "$CREATE_ERR" >&2
        APP_KV_STATUS+=("FAILED")
        OVERALL_FAILED=1
      fi
    fi
  fi
done

echo ""
echo "----------------------------------------"
echo "Verification summary"
echo "----------------------------------------"
printf '%-38s %-18s %-16s %-16s\n' "Container App" "Identity" "AcrPull" "KV Secrets User"
for i in "${!APP_NAMES[@]}"; do
  printf '%-38s %-18s %-16s %-16s\n' "${APP_NAMES[$i]}" "${APP_IDENTITY_STATUS[$i]}" "${APP_ACR_STATUS[$i]}" "${APP_KV_STATUS[$i]}"
done
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "RESULT: DRY RUN COMPLETE (no changes were made)"
  exit 0
fi

if [[ "$OVERALL_FAILED" -eq 1 ]]; then
  echo "RESULT: FAILED (one or more container apps did not reach the fully configured state)"
  exit 1
fi

echo "RESULT: PASSED (all container apps have a managed identity and both roles granted)"
exit 0
