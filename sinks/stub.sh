#!/usr/bin/env bash
# Stub sink (default): prints the normalized result to stdout and keeps a
# "latest" copy per profile/scenario under $RESULTS_DIR/latest/.
# Works with zero external dependencies.
set -euo pipefail

RESULT_FILE="${1:?result json required}"
: "${RESULTS_DIR:=/results}"
: "${DRY_RUN:=false}"

log() {
  printf '%s [sink:stub] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

PROFILE_NAME="$(jq --raw-output '.profile' "${RESULT_FILE}")"
SCENARIO_NAME="$(jq --raw-output '.scenario' "${RESULT_FILE}")"
LATEST_DIR="${RESULTS_DIR}/latest"
LATEST_FILE="${LATEST_DIR}/${PROFILE_NAME}-${SCENARIO_NAME}.json"

jq --compact-output '.' "${RESULT_FILE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "DRY_RUN: would write ${LATEST_FILE}"
  exit 0
fi

mkdir --parents "${LATEST_DIR}"
cp --force "${RESULT_FILE}" "${LATEST_FILE}"
log "wrote ${LATEST_FILE}"
