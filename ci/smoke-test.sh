#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
PROVIDER_NAME="${PROVIDER_NAME:-ci-oidc}"
USER_NAME="${USER_NAME:-ci-user}"

echo "========================================"
echo "Integration Aggregator E2E Smoke Test"
echo "========================================"

echo
echo "1. Registering OIDC provider..."

REGISTER_RESPONSE="$(
  curl --fail --silent --show-error \
    -X POST \
    -H "Content-Type: application/json" \
    "$BASE_URL/providers" \
    -d '{
      "name": "'"$PROVIDER_NAME"'",
      "provider": "oidc",
      "client_id": "ci-client",
      "client_secret": "ci-secret",
      "scopes": ["openid", "profile", "email"],
      "provider_options": {
        "issuer_url": "'"${OIDC_ISSUER_URL}"'"
      }
    }'
)"

echo "$REGISTER_RESPONSE" | jq .

echo "$REGISTER_RESPONSE" | jq -e \
  '.name == "'"$PROVIDER_NAME"'" and
   .provider == "oidc" and
   .client_id == "ci-client" and
   (.client_secret == null or (. | has("client_secret") | not))'

echo
echo "2. Requesting authorization URL..."

CONNECT_RESPONSE="$(
  curl --fail --silent --show-error \
    -X POST \
    "$BASE_URL/providers/$PROVIDER_NAME/users/$USER_NAME/connect"
)"

echo "$CONNECT_RESPONSE" | jq .

AUTH_URL="$(echo "$CONNECT_RESPONSE" | jq -r '.authorization_url')"
STATE="$(echo "$CONNECT_RESPONSE" | jq -r '.state')"

test -n "$AUTH_URL"
test -n "$STATE"

echo
echo "Authorization URL:"
echo "$AUTH_URL"

echo
echo "3. Following OAuth authorization redirect..."

AUTH_HEADERS="$(mktemp)"
trap 'rm -f "$AUTH_HEADERS"' EXIT

curl \
  --silent \
  --show-error \
  --output /dev/null \
  --dump-header "$AUTH_HEADERS" \
  --max-redirs 0 \
  "$AUTH_URL" || true

LOCATION="$(
  awk 'tolower($1) == "location:" {
    sub(/\r$/, "", $0)
    sub(/^[Ll]ocation:[[:space:]]*/, "", $0)
    print
    exit
  }' "$AUTH_HEADERS"
)"

if [[ -z "$LOCATION" ]]; then
  echo "ERROR: OAuth authorization endpoint did not return a redirect."
  cat "$AUTH_HEADERS"
  exit 1
fi

echo "Redirect:"
echo "$LOCATION"

CALLBACK_URL="$LOCATION"

echo
echo "4. Calling application callback..."

CALLBACK_RESPONSE="$(
  curl --fail --silent --show-error \
    "$CALLBACK_URL"
)"

echo "$CALLBACK_RESPONSE" | jq .

echo "$CALLBACK_RESPONSE" | jq -e \
  '.status == "connected" and
   .provider == "'"$PROVIDER_NAME"'" and
   .user == "'"$USER_NAME"'"'

echo
echo "5. Starting asynchronous token retrieval..."

RETRIEVAL_RESPONSE="$(
  curl --fail --silent --show-error \
    -X GET \
    "$BASE_URL/$PROVIDER_NAME/$USER_NAME"
)"

echo "$RETRIEVAL_RESPONSE" | jq .

REQUEST_ID="$(echo "$RETRIEVAL_RESPONSE" | jq -r '.request_id')"
LOCATION="$(echo "$RETRIEVAL_RESPONSE" | jq -r '.location')"

test -n "$REQUEST_ID"
test -n "$LOCATION"

echo
echo "6. Polling request status..."

for attempt in $(seq 1 30); do
  STATUS_RESPONSE="$(
    curl --fail --silent --show-error \
      "$LOCATION"
  )"

  STATUS="$(echo "$STATUS_RESPONSE" | jq -r '.status')"

  echo "Attempt $attempt: $STATUS"

  if [[ "$STATUS" == "completed" ]]; then
    echo
    echo "========================================"
    echo "E2E smoke test PASSED"
    echo "========================================"
    exit 0
  fi

  if [[ "$STATUS" == "failed" ]]; then
    echo "$STATUS_RESPONSE" | jq .
    echo "E2E smoke test FAILED"
    exit 1
  fi

  sleep 1
done

echo "Timed out waiting for asynchronous request."
exit 1
