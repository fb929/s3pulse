#!/usr/bin/env bash
# Runs ONE warp scenario and writes a normalized result JSON.
#
# Usage: run_scenario.sh '<scenario json>' <run_dir>
#
# Always writes <run_dir>/<scenario>.json (success=false with null metrics if
# warp could not run at all). Raw warp benchdata (<scenario>.json.zst), the
# warp log and the full `warp analyze --json` output are kept next to it.
#
# success rule: true only if warp exited 0 AND warp analyze succeeded AND errors == 0.
#
# Exit code: 0 if success=true, 1 otherwise.
set -euo pipefail

SCENARIO_JSON="${1:?scenario json required}"
RUN_DIR="${2:?run dir required}"

: "${PROFILE:=probe}"
: "${RUN_ID:=manual}"
: "${RUN_LABEL:=default}"
: "${DEFAULT_DURATION:=30}"
: "${DEFAULT_CONCURRENCY:=4}"
: "${S3_TLS:=false}"
: "${S3_TLS_INSECURE:=false}"
: "${S3_REGION:=us-east-1}"
: "${S3_LOOKUP:=path}"
: "${S3_BUCKET:=s3pulse}"
: "${S3PULSE_VERSION:=0.0.0}"
: "${WARP_EXTRA_ARGS:=}"
: "${S3_ENDPOINT:?S3_ENDPOINT required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY required}"

log() {
  printf '%s [run_scenario] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# ---- resolve effective scenario (defaults < scenario < overrides[PROFILE]) ----
EFFECTIVE="$(jq --compact-output \
  --arg profile "${PROFILE}" \
  --argjson default_duration "${DEFAULT_DURATION}" \
  --argjson default_concurrency "${DEFAULT_CONCURRENCY}" '
  (. + ((.overrides // {})[$profile] // {})) as $s
  | {
      name: $s.name,
      command: $s.command,
      obj_size: $s.obj_size,
      objects: $s.objects,
      extra_args: ($s.extra_args // []),
      concurrent: ($s.concurrent // $default_concurrency),
      duration: ($s.duration // $default_duration)
    }' <<< "${SCENARIO_JSON}")"

NAME="$(jq --raw-output '.name' <<< "${EFFECTIVE}")"
COMMAND="$(jq --raw-output '.command' <<< "${EFFECTIVE}")"
OBJ_SIZE="$(jq --raw-output '.obj_size // empty' <<< "${EFFECTIVE}")"
OBJECTS="$(jq --raw-output '.objects // empty' <<< "${EFFECTIVE}")"
CONCURRENT="$(jq --raw-output '.concurrent' <<< "${EFFECTIVE}")"
DURATION="$(jq --raw-output '.duration' <<< "${EFFECTIVE}")"
mapfile -t EXTRA_ARGS < <(jq --raw-output '.extra_args[]' <<< "${EFFECTIVE}")

RESULT_FILE="${RUN_DIR}/${NAME}.json"
BENCHDATA_BASE="${RUN_DIR}/${NAME}"
WARP_LOG="${RUN_DIR}/${NAME}.warp.log"
ANALYSIS_FILE="${RUN_DIR}/${NAME}.analysis.json"
TIMESTAMP="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"

# warp op type as it appears in `by_op_type` of the analysis output.
case "${COMMAND}" in
  put|multipart) OPERATION="PUT" ;;
  get)           OPERATION="GET" ;;
  list)          OPERATION="LIST" ;;
  stat)          OPERATION="STAT" ;;
  delete)        OPERATION="DELETE" ;;
  mixed)         OPERATION="MIXED" ;;
  *)             OPERATION="" ;;
esac

# ---- write a normalized result (metrics may be null) --------------------------
# $1 = warp exit code, $2 = analyze ok (true|false), $3 = analysis file (may be missing)
write_result() {
  local warp_exit="$1" analyze_ok="$2" analysis="$3"
  local analysis_json="null"
  if [[ "${analyze_ok}" == "true" && -s "${analysis}" ]]; then
    analysis_json="$(cat "${analysis}")"
  fi
  jq --null-input --compact-output \
    --arg run_id "${RUN_ID}" \
    --arg run_label "${RUN_LABEL}" \
    --arg profile "${PROFILE}" \
    --arg timestamp "${TIMESTAMP}" \
    --arg version "${S3PULSE_VERSION}" \
    --arg scenario "${NAME}" \
    --arg operation "${OPERATION}" \
    --arg obj_size "${OBJ_SIZE}" \
    --argjson concurrent "${CONCURRENT}" \
    --argjson configured_duration "${DURATION}" \
    --argjson warp_exit "${warp_exit}" \
    --argjson analysis "${analysis_json}" '
    # Select the aggregate for this operation; mixed uses the total.
    (if $analysis == null then null
     elif $operation == "MIXED" then $analysis.total
     else ($analysis.by_op_type[$operation] // null) end) as $agg
    | ($agg.throughput // null) as $tp
    | (if $tp.measure_duration_millis != null and $tp.measure_duration_millis > 0
       then ($tp.measure_duration_millis / 1000) else null end) as $dur_s
    | (if $dur_s != null and $tp.bytes != null then ($tp.bytes / $dur_s / 1048576) else null end) as $mib_s
    | (if $dur_s != null and $tp.objects != null then ($tp.objects / $dur_s) else null end) as $obj_s
    # Latency: warp reports percentiles per 10s segment per client; combine them
    # with a request-weighted mean (approximation, documented in README).
    | ([ ($agg.requests_by_client // {})[]? [] ? | .single_sized_requests // empty
         | select(.requests != null and .requests > 0) ]) as $segs
    | (reduce $segs[] as $s (0; . + $s.requests)) as $nreq
    | (if $nreq > 0 then {
         p50: ((reduce $segs[] as $s (0; . + ($s.dur_median_millis * $s.requests))) / $nreq),
         p90: ((reduce $segs[] as $s (0; . + ($s.dur_90_millis * $s.requests))) / $nreq),
         p99: ((reduce $segs[] as $s (0; . + ($s.dur_99_millis * $s.requests))) / $nreq)
       } else {p50: null, p90: null, p99: null} end) as $lat
    | ($agg.total_errors // $tp.errors // null) as $errors
    | {
        run_id: $run_id,
        run_label: $run_label,
        profile: $profile,
        timestamp: $timestamp,
        version: $version,
        scenario: $scenario,
        operation: $operation,
        throughput_mib_s: (if $mib_s == null then null else ($mib_s * 1000 | round / 1000) end),
        objects_per_s: (if $obj_s == null then null else ($obj_s * 1000 | round / 1000) end),
        latency_ms: ($lat | map_values(if . == null then null else (. * 1000 | round / 1000) end)),
        errors: $errors,
        duration_s: ($dur_s // $configured_duration),
        concurrent: $concurrent,
        obj_size: (if $obj_size == "" then null else $obj_size end),
        success: ($warp_exit == 0 and $analysis != null and $agg != null and (($errors // 1) == 0))
      }' > "${RESULT_FILE}"
}

# ---- sanity checks (emit failure result instead of crashing) -----------------
if [[ -z "${OPERATION}" ]]; then
  log "scenario ${NAME}: unknown warp command '${COMMAND}'"
  write_result 1 false ""
  exit 1
fi

# ---- build warp argument list (secrets go through environment only) ----------
WARP_ARGS=(
  "${COMMAND}"
  --bucket "${S3_BUCKET}"
  --lookup "${S3_LOOKUP}"
  --concurrent "${CONCURRENT}"
  --duration "${DURATION}s"
  --benchdata "${BENCHDATA_BASE}"
  --no-color
  --quiet
)
[[ -n "${OBJ_SIZE}" ]] && WARP_ARGS+=(--obj.size "${OBJ_SIZE}")
[[ -n "${OBJECTS}" ]] && WARP_ARGS+=(--objects "${OBJECTS}")
[[ "${S3_TLS_INSECURE}" == "true" ]] && WARP_ARGS+=(--insecure)
if ((${#EXTRA_ARGS[@]} > 0)); then
  WARP_ARGS+=("${EXTRA_ARGS[@]}")
fi
if [[ -n "${WARP_EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206  # intentional word splitting of a flag list
  WARP_ARGS+=(${WARP_EXTRA_ARGS})
fi

# Give warp time for prepare (uploads) + benchmark + cleanup before killing it.
WARP_TIMEOUT="$((DURATION * 3 + 180))"

log "scenario ${NAME}: warp ${WARP_ARGS[*]} (timeout ${WARP_TIMEOUT}s)"

# Propagate SIGTERM to warp so it can clean up the bucket.
WARP_PID=""
# shellcheck disable=SC2329  # invoked by trap
forward_signal() {
  if [[ -n "${WARP_PID}" ]]; then
    kill -TERM "${WARP_PID}" 2>/dev/null || true
  fi
}
trap forward_signal TERM INT

WARP_EXIT=0
# Credentials are passed as environment variables (WARP_* are read by warp,
# verified in cli/flags.go), never as CLI arguments.
WARP_HOST="${S3_ENDPOINT}" \
WARP_ACCESS_KEY="${S3_ACCESS_KEY}" \
WARP_SECRET_KEY="${S3_SECRET_KEY}" \
WARP_REGION="${S3_REGION}" \
WARP_TLS="${S3_TLS}" \
timeout --signal=TERM --kill-after=30 "${WARP_TIMEOUT}" warp "${WARP_ARGS[@]}" > "${WARP_LOG}" 2>&1 &
WARP_PID=$!
wait "${WARP_PID}" || WARP_EXIT=$?
WARP_PID=""
trap - TERM INT

if [[ "${WARP_EXIT}" != "0" ]]; then
  log "scenario ${NAME}: warp exited ${WARP_EXIT} (see ${WARP_LOG})"
  tail --lines=5 "${WARP_LOG}" | sed 's/^/    /' >&2 || true
fi

# ---- analyze ------------------------------------------------------------------
ANALYZE_OK=false
BENCHDATA_FILE="${BENCHDATA_BASE}.json.zst"
if [[ -s "${BENCHDATA_FILE}" ]]; then
  if warp analyze --json --no-color --quiet "${BENCHDATA_FILE}" > "${ANALYSIS_FILE}" 2>> "${WARP_LOG}" \
     && jq --exit-status 'type == "object"' "${ANALYSIS_FILE}" >/dev/null 2>&1; then
    ANALYZE_OK=true
  else
    log "scenario ${NAME}: warp analyze failed"
  fi
else
  log "scenario ${NAME}: no benchdata produced at ${BENCHDATA_FILE}"
fi

write_result "${WARP_EXIT}" "${ANALYZE_OK}" "${ANALYSIS_FILE}"

if jq --exit-status '.success' "${RESULT_FILE}" >/dev/null; then
  exit 0
fi
exit 1
