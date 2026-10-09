#!/usr/bin/env bash
# HTTP JSON sink: POSTs the normalized result JSON to SINK_URL.
# Retries 3 times with exponential backoff (1s, 2s, 4s); fails softly (exit 1,
# the caller logs and continues). Optional SINK_HTTP_BEARER_TOKEN is sent as a
# Bearer token and never printed.
set -euo pipefail

RESULT_FILE="${1:?result json required}"
: "${SINK_URL:=}"
: "${DRY_RUN:=false}"
: "${SINK_HTTP_BEARER_TOKEN:=}"
MAX_ATTEMPTS=3

log() {
  printf '%s [sink:http_json] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

[[ -n "${SINK_URL}" ]] || { log "SINK_URL is required (full URL to POST to)"; exit 1; }

SCENARIO_NAME="$(jq --raw-output '.scenario' "${RESULT_FILE}")"
BODY="$(jq --compact-output '.' "${RESULT_FILE}")"

CURL_HEADERS=(--header "Content-Type: application/json")
if [[ -n "${SINK_HTTP_BEARER_TOKEN}" ]]; then
  CURL_HEADERS+=(--header "Authorization: Bearer ${SINK_HTTP_BEARER_TOKEN}")
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'DRY_RUN http_json request:\nPOST %s\nContent-Type: application/json\n' "${SINK_URL}"
  if [[ -n "${SINK_HTTP_BEARER_TOKEN}" ]]; then
    printf 'Authorization: Bearer ***\n'
  fi
  printf '\n%s\n\n' "${BODY}"
  exit 0
fi

attempt=1
delay=1
while true; do
  if printf '%s' "${BODY}" | curl --silent --show-error --fail \
      --request POST \
      "${CURL_HEADERS[@]}" \
      --max-time 15 \
      --data-binary @- \
      --output /dev/null \
      "${SINK_URL}"; then
    log "posted ${SCENARIO_NAME} to ${SINK_URL} (attempt ${attempt})"
    exit 0
  fi
  if ((attempt >= MAX_ATTEMPTS)); then
    log "POST to ${SINK_URL} failed after ${attempt} attempts"
    exit 1
  fi
  log "POST to ${SINK_URL} failed (attempt ${attempt}), retrying in ${delay}s"
  sleep "${delay}"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
done
