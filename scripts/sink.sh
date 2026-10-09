#!/usr/bin/env bash
# Dispatches one normalized result JSON to the sink selected by SINK_TYPE.
#
# Usage: sink.sh <result.json>
# Exit code: the sink's exit code (callers must treat failure as soft).
set -euo pipefail

RESULT_FILE="${1:?result json required}"
: "${SINK_TYPE:=stub}"
S3PULSE_HOME="${S3PULSE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log() {
  printf '%s [sink] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

[[ -s "${RESULT_FILE}" ]] || { log "result file missing or empty: ${RESULT_FILE}"; exit 1; }
jq --exit-status 'type == "object" and has("scenario")' "${RESULT_FILE}" >/dev/null \
  || { log "result file is not a normalized s3pulse result: ${RESULT_FILE}"; exit 1; }

case "${SINK_TYPE}" in
  stub|pushgateway|http_json) ;;
  *) log "unknown SINK_TYPE '${SINK_TYPE}'"; exit 1 ;;
esac

SINK_SCRIPT="${S3PULSE_HOME}/sinks/${SINK_TYPE}.sh"
[[ -x "${SINK_SCRIPT}" ]] || { log "sink script not executable: ${SINK_SCRIPT}"; exit 1; }

exec "${SINK_SCRIPT}" "${RESULT_FILE}"
