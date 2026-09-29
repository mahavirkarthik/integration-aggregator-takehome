#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-integration}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-openbao}"
OPENBAO_SERVICE="openbao.${NAMESPACE}.svc:8200"

PLUGIN_NAME="oauthapp"
PLUGIN_VERSION="v3.4.1"
PLUGIN_SHA256="b9b5b2c752889ffe7d708522d6726752f8bba972769693cf5c84b7ce64a60ec5"

APP_TOKEN_SECRET="integration-aggregator-openbao-token"
APP_POLICY="integration-aggregator"

echo "Waiting for OpenBao pod..."

for i in $(seq 1 90); do
  if kubectl get pod/openbao-0 -n "$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl wait \
  --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running \
  pod/openbao-0 \
  --timeout=180s

echo "Checking OpenBao initialization state..."

STATUS_JSON=""
STATUS_EXIT=0

set +e
STATUS_JSON="$(
  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    bao status -format=json 2>/dev/null
)"
STATUS_EXIT=$?
set -e

# OpenBao returns exit code 2 when it is sealed.
# A sealed OpenBao is expected before initialization/unsealing.
if [[ "$STATUS_EXIT" -ne 0 && "$STATUS_EXIT" -ne 2 ]]; then
  echo "ERROR: OpenBao status check failed with exit code $STATUS_EXIT"
  exit "$STATUS_EXIT"
fi

INITIALIZED="$(echo "$STATUS_JSON" | jq -r '.initialized')"
SEALED="$(echo "$STATUS_JSON" | jq -r '.sealed')"

echo "OpenBao initialized: $INITIALIZED"
echo "OpenBao sealed: $SEALED"

if [[ "$INITIALIZED" == "false" ]]; then
  echo "Initializing OpenBao..."

  INIT_JSON="$(
    kubectl exec -n "$NAMESPACE" openbao-0 -- \
      bao operator init \
        -format=json \
        -key-shares=1 \
        -key-threshold=1
  )"

  UNSEAL_KEY="$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[0]')"
  ROOT_TOKEN="$(echo "$INIT_JSON" | jq -r '.root_token')"

  if [[ -z "$UNSEAL_KEY" || "$UNSEAL_KEY" == "null" ]]; then
    echo "ERROR: Failed to obtain OpenBao unseal key."
    exit 1
  fi

  if [[ -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to obtain OpenBao root token."
    exit 1
  fi

  echo "Unsealing OpenBao..."

  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    bao operator unseal "$UNSEAL_KEY"

  echo "Registering OAuth plugin..."

  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    env BAO_TOKEN="$ROOT_TOKEN" \
    bao plugin register \
      -sha256="$PLUGIN_SHA256" \
      -version="$PLUGIN_VERSION" \
      secret "$PLUGIN_NAME"

  echo "Enabling OAuth secrets engine..."

  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    env BAO_TOKEN="$ROOT_TOKEN" \
    bao secrets enable \
      -path=oauth2 \
      "$PLUGIN_NAME"

  echo "Creating application policy..."

  POLICY_CONTENT="$(cat <<'POLICY'
path "oauth2/servers/*" {
  capabilities = ["create", "read", "update"]
}

path "oauth2/auth-code-url" {
  capabilities = ["update"]
}

path "oauth2/creds/*" {
  capabilities = ["create", "read", "update"]
}
POLICY
)"

  printf '%s\n' "$POLICY_CONTENT" | \
    kubectl exec -i -n "$NAMESPACE" openbao-0 -- \
      env BAO_TOKEN="$ROOT_TOKEN" \
      bao policy write "$APP_POLICY" -

  echo "Creating restricted application token..."

  APP_TOKEN="$(
    kubectl exec -n "$NAMESPACE" openbao-0 -- \
      env BAO_TOKEN="$ROOT_TOKEN" \
      bao token create \
        -policy="$APP_POLICY" \
        -orphan \
        -format=json \
      | jq -r '.auth.client_token'
  )"

  if [[ -z "$APP_TOKEN" || "$APP_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to create restricted application token."
    exit 1
  fi

  echo "Storing application token in Kubernetes Secret..."

  kubectl create secret generic "$APP_TOKEN_SECRET" \
    --namespace "$NAMESPACE" \
    --from-literal=openbao-token="$APP_TOKEN" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

  unset ROOT_TOKEN
  unset UNSEAL_KEY
  unset APP_TOKEN
  unset POLICY_CONTENT

  echo "OpenBao bootstrap completed."

else
  echo "OpenBao is already initialized."

  if [[ "$SEALED" == "true" ]]; then
    echo "ERROR: OpenBao is initialized but sealed."
    echo "The existing unseal key is not available to the bootstrap script."
    echo "Recreate the local OpenBao data or provide the unseal key."
    exit 1
  fi

  if ! kubectl get secret "$APP_TOKEN_SECRET" \
      -n "$NAMESPACE" >/dev/null 2>&1; then

    echo "ERROR: OpenBao is initialized but the application token Secret is missing."
    echo "This usually means OpenBao was initialized manually."
    echo "Create the application token manually or recreate the local OpenBao data."
    exit 1
  fi
fi

echo "Waiting for OpenBao to become ready..."

kubectl wait \
  --namespace "$NAMESPACE" \
  --for=condition=Ready \
  pod/openbao-0 \
  --timeout=120s

echo "Verifying OpenBao..."

kubectl exec -n "$NAMESPACE" openbao-0 -- \
  bao status

echo "OpenBao is ready."
