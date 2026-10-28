#!/usr/bin/env bash
#
# generate-container-config.sh
#
# Generates an Azure Container App deployment YAML (for
# `az containerapp update --yaml <file>`) for one service in one environment.
# Values come from the caller's manifest, which is the single source of truth.
#
# Shared script: lives in mastec-ops and is run by the deploy workflow from the
# caller repo's root. The caller sets MANIFEST_PATH to its manifest file.
#
# Usage (from the caller repo root):
#   MANIFEST_PATH=<manifest.json> bash shared/scripts/generate-container-config.sh \
#     <dev|qa|prod> <service> <image> [--output <path>] [--app <name>]
#
# Exit codes:
#   0 - YAML generated successfully
#   1 - invalid arguments, missing manifest, or manifest lookup failure
#
set -euo pipefail

# Manifest path is relative to the caller repo root (where the script is run).
MANIFEST="${MANIFEST_PATH:?MANIFEST_PATH must be set by the calling workflow}"

usage() {
  echo "Usage: $0 <dev|qa|prod> <service> <image> [--output <path>] [--app <name>]" >&2
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

ENV_NAME="$1"
SERVICE="$2"
IMAGE="$3"
shift 3

OUTPUT=""
APP_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --app)
      APP_OVERRIDE="$2"
      shift 2
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

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest file not found: $MANIFEST" >&2
  exit 1
fi

if ! jq -e --arg s "$SERVICE" '.services | has($s)' "$MANIFEST" >/dev/null 2>&1; then
  echo "ERROR: service '$SERVICE' not found in manifest (.services)" >&2
  exit 1
fi

# jq -r emits CRLF line endings on Windows. Every jq -r call is piped through
# `tr -d '\r'` so values stay clean.
VAULT_URL=$(jq -r --arg e "$ENV_NAME" '.environments[$e].vaultUrl' "$MANIFEST" | tr -d '\r')
IDENTITY=$(jq -r --arg e "$ENV_NAME" '.environments[$e].identity' "$MANIFEST" | tr -d '\r')
ACR=$(jq -r --arg e "$ENV_NAME" '.environments[$e].acr' "$MANIFEST" | tr -d '\r')

if [[ -z "$VAULT_URL" || "$VAULT_URL" == "null" ]]; then
  echo "ERROR: environments.$ENV_NAME.vaultUrl is missing in manifest" >&2
  exit 1
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "null" ]]; then
  echo "ERROR: environments.$ENV_NAME.identity is missing in manifest" >&2
  exit 1
fi
if [[ -z "$ACR" || "$ACR" == "null" ]]; then
  echo "ERROR: environments.$ENV_NAME.acr is missing in manifest" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Key Vault vars for this environment. Each services.<service>.vars.<VAR>
# entry is a per-environment map. A var with no entry for this environment is
# left out rather than causing an error.
# ---------------------------------------------------------------------------
declare -A KV_VARS=()

VAR_NAMES=$(jq -r --arg s "$SERVICE" '.services[$s].vars | keys[]?' "$MANIFEST" | tr -d '\r')
while IFS= read -r var; do
  [[ -z "$var" ]] && continue
  kv=$(jq -r --arg s "$SERVICE" --arg v "$var" --arg e "$ENV_NAME" '.services[$s].vars[$v][$e] // empty' "$MANIFEST" | tr -d '\r')
  [[ -z "$kv" ]] && continue
  KV_VARS["$var"]="$kv"
done <<< "$VAR_NAMES"

# literalVars.<VAR>.<env>: plain, non-secret values such as ENV=dev.
declare -A LITERAL_VARS=()

LITERAL_NAMES=$(jq -r --arg s "$SERVICE" '.services[$s].literalVars | keys[]?' "$MANIFEST" | tr -d '\r')
while IFS= read -r var; do
  [[ -z "$var" ]] && continue
  val=$(jq -r --arg s "$SERVICE" --arg v "$var" --arg e "$ENV_NAME" '.services[$s].literalVars[$v][$e] // empty' "$MANIFEST" | tr -d '\r')
  [[ -z "$val" ]] && continue
  LITERAL_VARS["$var"]="$val"
done <<< "$LITERAL_NAMES"

VAR_COUNT=$(( ${#KV_VARS[@]} + ${#LITERAL_VARS[@]} ))
if [[ "$VAR_COUNT" -eq 0 ]]; then
  echo "WARNING: no env vars resolved for service '$SERVICE' in environment '$ENV_NAME'" >&2
fi

# ---------------------------------------------------------------------------
# Container app name: --app if given, otherwise the service's first
# containerApps entry with {env} replaced by the environment name.
# ---------------------------------------------------------------------------
if [[ -n "$APP_OVERRIDE" ]]; then
  APP_NAME="$APP_OVERRIDE"
else
  CONTAINER_APP_TEMPLATE=$(jq -r --arg s "$SERVICE" '.services[$s].containerApps[0] // empty' "$MANIFEST" | tr -d '\r')
  if [[ -z "$CONTAINER_APP_TEMPLATE" ]]; then
    echo "ERROR: services.$SERVICE.containerApps is empty in manifest; pass --app explicitly" >&2
    exit 1
  fi
  APP_NAME="${CONTAINER_APP_TEMPLATE/\{env\}/$ENV_NAME}"
fi

CPU=$(jq -r --arg s "$SERVICE" '.services[$s].resources.cpu' "$MANIFEST" | tr -d '\r')
MEMORY=$(jq -r --arg s "$SERVICE" '.services[$s].resources.memory' "$MANIFEST" | tr -d '\r')
MIN_REPLICAS=$(jq -r --arg s "$SERVICE" '.services[$s].scaling.minReplicas' "$MANIFEST" | tr -d '\r')
MAX_REPLICAS=$(jq -r --arg s "$SERVICE" '.services[$s].scaling.maxReplicas' "$MANIFEST" | tr -d '\r')

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${SERVICE}-config.yaml"
fi

# Key Vault secret names use dashes; env var names use underscores.
to_kebab() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# Sort var names so the output is the same on every run.
SORTED_KV_KEYS=$(printf '%s\n' "${!KV_VARS[@]}" | sort)
SORTED_LITERAL_KEYS=""
if [[ "${#LITERAL_VARS[@]}" -gt 0 ]]; then
  SORTED_LITERAL_KEYS=$(printf '%s\n' "${!LITERAL_VARS[@]}" | sort)
fi

{
  echo "properties:"
  echo "  configuration:"
  echo "    secrets:"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    kebab=$(to_kebab "$key")
    kv="${KV_VARS[$key]}"
    echo "      - name: ${kebab}"
    echo "        keyVaultUrl: ${VAULT_URL}/secrets/${kv}"
    echo "        identity: ${IDENTITY}"
  done <<< "$SORTED_KV_KEYS"
  # Registry login uses the app's managed identity, not an ACR admin password.
  # This entry replaces any old passwordSecretRef, which would otherwise be left
  # pointing at a secret that the update removes.
  echo "    registries:"
  echo "      - server: ${ACR}.azurecr.io"
  echo "        identity: ${IDENTITY}"
  echo "  template:"
  echo "    containers:"
  echo "      - name: ${APP_NAME}"
  echo "        image: ${IMAGE}"
  echo "        resources:"
  echo "          cpu: ${CPU}"
  echo "          memory: ${MEMORY}"
  echo "        env:"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    kebab=$(to_kebab "$key")
    echo "          - name: ${key}"
    echo "            secretRef: ${kebab}"
  done <<< "$SORTED_KV_KEYS"
  if [[ -n "$SORTED_LITERAL_KEYS" ]]; then
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      echo "          - name: ${key}"
      echo "            value: \"${LITERAL_VARS[$key]}\""
    done <<< "$SORTED_LITERAL_KEYS"
  fi
  echo "    scale:"
  echo "      minReplicas: ${MIN_REPLICAS}"
  echo "      maxReplicas: ${MAX_REPLICAS}"
} > "$OUTPUT"

echo "----------------------------------------"
echo "Container App config generated"
echo "----------------------------------------"
echo "Environment:    $ENV_NAME"
echo "Service:        $SERVICE"
echo "Container app:  $APP_NAME"
echo "Image:          $IMAGE"
echo "Vars included:  $VAR_COUNT"
echo "Resources:      cpu=$CPU memory=$MEMORY"
echo "Scaling:        minReplicas=$MIN_REPLICAS maxReplicas=$MAX_REPLICAS"
echo "Output path:    $OUTPUT"
