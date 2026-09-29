#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
PROVIDER="${PROVIDER:-perf-oidc}"
USER="${USER_NAME:-perf-user}"
CONCURRENCY="${CONCURRENCY:-3}"
REQUESTS="${REQUESTS:-30}"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

echo "Preparing performance test provider..."

REGISTER_RESPONSE="$(
  curl --silent --show-error \
    -X POST \
    -H "Content-Type: application/json" \
    -w '\n%{http_code}' \
    "$BASE_URL/providers" \
    -d '{
      "name": "'"$PROVIDER"'",
      "provider": "oidc",
      "client_id": "perf-client",
      "client_secret": "perf-secret",
      "scopes": ["openid", "profile", "email"],
      "provider_options": {
        "issuer_url": "'"${OIDC_ISSUER_URL:-http://localhost:30080/default}"'"
      }
    }'
)"

HTTP_CODE="$(echo "$REGISTER_RESPONSE" | tail -n 1)"
REGISTER_BODY="$(echo "$REGISTER_RESPONSE" | sed '$d')"

if [[ "$HTTP_CODE" == "201" ]]; then
  echo "Performance provider created."
  echo "$REGISTER_BODY" | jq .
elif [[ "$HTTP_CODE" == "409" ]]; then
  echo "Performance provider already exists; reusing it."
else
  echo "ERROR: Failed to register performance provider."
  echo "HTTP status: $HTTP_CODE"
  echo "$REGISTER_BODY" | jq . 2>/dev/null || echo "$REGISTER_BODY"
  exit 1
fi

URL="${BASE_URL}/${PROVIDER}/${USER}"

echo
echo "Performance test"
echo "URL: ${URL}"
echo "Concurrency: ${CONCURRENCY}"
echo "Requests: ${REQUESTS}"
echo

start_ns=$(date +%s%N)

seq "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} \
  curl -sS -o /dev/null \
  -w '%{http_code} %{time_total}\n' \
  "$URL" >> "$tmp_file"

end_ns=$(date +%s%N)

awk '
{
  status[$1]++
  times[++n] = $2
}
END {
  if (n == 0) {
    print "No requests completed"
    exit 1
  }

  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (times[j] < times[i]) {
        tmp = times[i]
        times[i] = times[j]
        times[j] = tmp
      }
    }
  }

  p50_index = int(n * 0.50)
  if (p50_index < 1) p50_index = 1

  p95_index = int(n * 0.95)
  if (p95_index < 1) p95_index = 1
  if (p95_index > n) p95_index = n

  print "Completed requests:", n
  print "HTTP 202:", status["202"] + 0
  print "Other responses:", n - (status["202"] + 0)

  printf "p50 latency: %.3f ms\n", times[p50_index] * 1000
  printf "p95 latency: %.3f ms\n", times[p95_index] * 1000
}
' "$tmp_file"

duration_ns=$((end_ns - start_ns))

awk -v requests="$REQUESTS" -v duration_ns="$duration_ns" '
BEGIN {
  duration = duration_ns / 1000000000

  if (duration > 0) {
    printf "Throughput: %.2f requests/sec\n", requests / duration
  }
}'
