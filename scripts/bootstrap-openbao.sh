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

kubectl wait \
  --namespace "$NAMESPACE" \
  --for=condition=Ready \
  pod/openbao-0 \
  --timeout=180s

echo "Checking OpenBao initialization state..."

INITIALIZED="$(
  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    bao status -format=json 2>/dev/null \
    | jq -r '.initialized'
)"

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

  echo "Unsealing OpenBao..."

  kubectl exec -n "$NAMESPACE" openbao-0 -- \
    bao operator unseal "$UNSEAL_KEY"

  echo "Registering OAuth plugin..."

  kubectl exec -n "$NAMESPACE" \
    -e BAO_TOKEN="$ROOT_TOKEN" \
    openbao-0 -- \
    bao plugin register \
      -sha256="$PLUGIN_SHA256" \
      -version="$PLUGIN_VERSION" \
      secret "$PLUGIN_NAME"

  echo "Enabling OAuth secrets engine..."

  kubectl exec -n "$NAMESPACE" \
    -e BAO_TOKEN="$ROOT_TOKEN" \
    openbao-0 -- \
    bao secrets enable \
      -path=oauth2 \
      "$PLUGIN_NAME"

  echo "Creating application policy..."

  kubectl exec -n "$NAMESPACE" \
    -e BAO_TOKEN="$ROOT_TOKEN" \
    openbao-0 -- \
    bao policy write "$APP_POLICY" - <<'POLICY'
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

  echo "Creating restricted application token..."

  APP_TOKEN="$(
    kubectl exec -n "$NAMESPACE" \
      -e BAO_TOKEN="$ROOT_TOKEN" \
      openbao-0 -- \
      bao token create \
        -policy="$APP_POLICY" \
        -orphan \
        -format=json \
      | jq -r '.auth.client_token'
  )"

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

  echo "OpenBao bootstrap completed."

else
  echo "OpenBao is already initialized."

  if ! kubectl get secret "$APP_TOKEN_SECRET" \
      -n "$NAMESPACE" >/dev/null 2>&1; then

    echo "ERROR: OpenBao is initialized but the application token Secret is missing."
    echo "This usually means OpenBao was initialized manually."
    echo "Create the application token manually or recreate the local OpenBao data."
    exit 1
  fi
fi

echo "Verifying OpenBao..."

kubectl exec -n "$NAMESPACE" openbao-0 -- \
  bao status

echo "OpenBao is ready."
