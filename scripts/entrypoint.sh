#!/usr/bin/env bash
# s3pulse entrypoint: validates config, selects the profile, runs the matching
# scenarios sequentially (optionally in an interval loop) and dispatches every
# result to the configured sink.
#
# Exit code (single-run mode): 0 if every scenario succeeded, 1 otherwise.
# Interval mode: loops until SIGTERM/SIGINT, then exits 0.
set -euo pipefail

S3PULSE_HOME="${S3PULSE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
SCENARIOS_FILE="${SCENARIOS_FILE:-${S3PULSE_HOME}/scenarios.json}"
export S3PULSE_HOME RESULTS_DIR

# ---- defaults -----------------------------------------------------------------
: "${PROFILE:=probe}"
: "${S3_TLS:=false}"
: "${S3_TLS_INSECURE:=false}"
: "${S3_REGION:=us-east-1}"
: "${S3_LOOKUP:=path}"
: "${S3_BUCKET:=s3pulse}"
: "${DEFAULT_DURATION:=30}"
: "${DEFAULT_CONCURRENCY:=4}"
: "${SINK_TYPE:=stub}"
: "${SINK_URL:=}"
: "${RUN_LABEL:=default}"
: "${RUN_INTERVAL_SECONDS:=}"
: "${DRY_RUN:=false}"
: "${WARP_EXTRA_ARGS:=}"
export PROFILE S3_TLS S3_TLS_INSECURE S3_REGION S3_LOOKUP S3_BUCKET \
  DEFAULT_DURATION DEFAULT_CONCURRENCY SINK_TYPE SINK_URL RUN_LABEL DRY_RUN WARP_EXTRA_ARGS

S3PULSE_VERSION="$(tr --delete '[:space:]' < "${S3PULSE_HOME}/VERSION")"
export S3PULSE_VERSION

log() {
  printf '%s [entrypoint] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

# ---- validation (never print secrets) ----------------------------------------
[[ -n "${S3_ENDPOINT:-}" ]] || die "S3_ENDPOINT is required (host:port, no scheme)"
[[ "${S3_ENDPOINT}" != *"://"* ]] || die "S3_ENDPOINT must not contain a scheme, use S3_TLS=true for https"
[[ -n "${S3_ACCESS_KEY:-}" ]] || die "S3_ACCESS_KEY is required"
[[ -n "${S3_SECRET_KEY:-}" ]] || die "S3_SECRET_KEY is required"
case "${PROFILE}" in probe|load) ;; *) die "PROFILE must be probe or load (got '${PROFILE}')" ;; esac
case "${S3_LOOKUP}" in path|dns) ;; *) die "S3_LOOKUP must be path or dns (got '${S3_LOOKUP}')" ;; esac
case "${SINK_TYPE}" in stub|pushgateway|http_json) ;; *) die "SINK_TYPE must be stub, pushgateway or http_json" ;; esac
[[ "${RUN_LABEL}" =~ ^[A-Za-z0-9._-]+$ ]] || die "RUN_LABEL may only contain A-Z a-z 0-9 . _ -"
[[ "${DEFAULT_DURATION}" =~ ^[0-9]+$ ]] || die "DEFAULT_DURATION must be an integer (seconds)"
[[ "${DEFAULT_CONCURRENCY}" =~ ^[0-9]+$ ]] || die "DEFAULT_CONCURRENCY must be an integer"
[[ -z "${RUN_INTERVAL_SECONDS}" || "${RUN_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || die "RUN_INTERVAL_SECONDS must be empty or an integer"
[[ -r "${SCENARIOS_FILE}" ]] || die "scenarios file not readable: ${SCENARIOS_FILE}"
jq --exit-status '.scenarios | type == "array"' "${SCENARIOS_FILE}" >/dev/null || die "invalid scenarios.json"
command -v warp >/dev/null || die "warp binary not found in PATH"

mkdir --parents "${RESULTS_DIR}"

# ---- overlap protection -------------------------------------------------------
exec 9>"${RESULTS_DIR}/.s3pulse.lock"
if ! flock --nonblock 9; then
  die "another s3pulse run holds ${RESULTS_DIR}/.s3pulse.lock, refusing to overlap"
fi

# ---- signal handling ----------------------------------------------------------
STOP_REQUESTED=0
CHILD_PID=""
# shellcheck disable=SC2329  # invoked by trap
on_signal() {
  STOP_REQUESTED=1
  log "termination requested, finishing current step"
  if [[ -n "${CHILD_PID}" ]]; then
    kill -TERM "${CHILD_PID}" 2>/dev/null || true
  fi
}
trap on_signal TERM INT

# Run a command in the background and wait for it so traps fire immediately.
# Returns the command's exit code.
run_interruptible() {
  "$@" &
  CHILD_PID=$!
  local rc=0
  wait "${CHILD_PID}" || rc=$?
  CHILD_PID=""
  return "${rc}"
}

# ---- one full run of the selected profile -----------------------------------
# Prints "scenario<TAB>success<TAB>throughput<TAB>objects_per_s<TAB>p50<TAB>errors" lines
# to the summary file; returns 1 if any scenario did not succeed.
run_profile_once() {
  local run_id run_dir summary_file failed=0
  run_id="$(date --utc +%Y%m%dT%H%M%SZ)-$(od --address-radix=n --format=x2 --read-bytes=2 /dev/urandom | tr --delete ' \n')"
  run_dir="${RESULTS_DIR}/${run_id}"
  summary_file="${run_dir}/summary.tsv"
  mkdir --parents "${run_dir}"
  export RUN_ID="${run_id}"

  log "run ${run_id}: profile=${PROFILE} label=${RUN_LABEL} endpoint=${S3_ENDPOINT} bucket=${S3_BUCKET} sink=${SINK_TYPE} dry_run=${DRY_RUN}"

  local scenario_count
  scenario_count="$(jq --raw-output --arg profile "${PROFILE}" \
    '[.scenarios[] | select(.profiles | index($profile))] | length' "${SCENARIOS_FILE}")"
  if [[ "${scenario_count}" == "0" ]]; then
    log "no scenarios match profile ${PROFILE}"
    return 1
  fi

  printf 'scenario\tsuccess\tthroughput_mib_s\tobjects_per_s\tp50_ms\terrors\n' > "${summary_file}"

  local scenario_json scenario_name result_file
  while IFS= read -r scenario_json; do
    if [[ "${STOP_REQUESTED}" == "1" ]]; then
      log "stop requested, skipping remaining scenarios"
      failed=1
      break
    fi
    scenario_name="$(jq --raw-output '.name' <<< "${scenario_json}")"
    log "scenario ${scenario_name}: starting"
    result_file="${run_dir}/${scenario_name}.json"

    # run_scenario.sh always writes a normalized JSON, even on failure.
    if ! run_interruptible "${S3PULSE_HOME}/scripts/run_scenario.sh" "${scenario_json}" "${run_dir}"; then
      log "scenario ${scenario_name}: FAILED"
      failed=1
    else
      log "scenario ${scenario_name}: ok"
    fi

    if [[ -s "${result_file}" ]]; then
      jq --raw-output '[.scenario, .success, .throughput_mib_s, .objects_per_s, .latency_ms.p50, .errors] | @tsv' \
        "${result_file}" >> "${summary_file}"
      # A sink failure is logged but never aborts the remaining scenarios.
      if ! run_interruptible "${S3PULSE_HOME}/scripts/sink.sh" "${result_file}"; then
        log "scenario ${scenario_name}: sink ${SINK_TYPE} FAILED (result kept in ${result_file})"
      fi
    else
      log "scenario ${scenario_name}: no result file produced"
      printf '%s\tfalse\t\t\t\t\n' "${scenario_name}" >> "${summary_file}"
      failed=1
    fi
  done < <(jq --compact-output --arg profile "${PROFILE}" \
    '.scenarios[] | select(.profiles | index($profile))' "${SCENARIOS_FILE}")

  log "run ${run_id} summary (results in ${run_dir}):"
  awk --field-separator '\t' '{ printf "  %-16s %-8s %-18s %-14s %-10s %s\n", $1, $2, $3, $4, $5, $6 }' "${summary_file}" >&2
  return "${failed}"
}

# ---- main ---------------------------------------------------------------------
log "s3pulse ${S3PULSE_VERSION} starting (warp: $(warp --version 2>/dev/null | head --lines=1 || echo unknown))"

if [[ -z "${RUN_INTERVAL_SECONDS}" ]]; then
  if run_profile_once; then
    log "all scenarios succeeded"
    exit 0
  fi
  log "one or more scenarios failed"
  exit 1
fi

log "interval mode: running profile ${PROFILE} every ${RUN_INTERVAL_SECONDS}s"
while [[ "${STOP_REQUESTED}" == "0" ]]; do
  run_profile_once || log "run finished with failures, continuing loop"
  if [[ "${STOP_REQUESTED}" == "1" ]]; then
    break
  fi
  log "sleeping ${RUN_INTERVAL_SECONDS}s"
  run_interruptible sleep "${RUN_INTERVAL_SECONDS}" || true
done
log "stopped gracefully"
exit 0
