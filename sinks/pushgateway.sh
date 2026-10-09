#!/usr/bin/env bash
# Prometheus Pushgateway sink.
#
# PUT <SINK_URL>/metrics/job/s3pulse/instance/<RUN_LABEL>/profile/<profile>/scenario/<scenario>
#
# The grouping key (job, instance, profile, scenario) is stable across runs, so
# every run replaces the previous push for the same scenario and series stay
# continuous. run_id is intentionally NOT a label. Metrics with null values are
# skipped (never pushed as zero).
set -euo pipefail

RESULT_FILE="${1:?result json required}"
: "${SINK_URL:=}"
: "${DRY_RUN:=false}"

log() {
  printf '%s [sink:pushgateway] %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

[[ -n "${SINK_URL}" ]] || { log "SINK_URL is required (e.g. http://pushgateway:9091)"; exit 1; }

RUN_LABEL_VALUE="$(jq --raw-output '.run_label' "${RESULT_FILE}")"
PROFILE_NAME="$(jq --raw-output '.profile' "${RESULT_FILE}")"
SCENARIO_NAME="$(jq --raw-output '.scenario' "${RESULT_FILE}")"

for value in "${RUN_LABEL_VALUE}" "${PROFILE_NAME}" "${SCENARIO_NAME}"; do
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || { log "label value '${value}' contains characters not allowed in the grouping key"; exit 1; }
done

PUSH_URL="${SINK_URL%/}/metrics/job/s3pulse/instance/${RUN_LABEL_VALUE}/profile/${PROFILE_NAME}/scenario/${SCENARIO_NAME}"

# Build the text exposition body. Labels on every sample: operation.
BODY="$(jq --raw-output '
  def esc: gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
  # Emit "# TYPE" only for metrics that have at least one non-null sample.
  def metric(name; samples): (samples | map(select(. != null))) as $s
    | if ($s | length) > 0 then ["# TYPE \(name) gauge"] + $s else [] end;
  ("operation=\"" + ((.operation // "") | esc) + "\"") as $labels
  | (.timestamp | fromdateiso8601) as $ts
  | metric("s3pulse_throughput_mib_s";
      [ if .throughput_mib_s != null then "s3pulse_throughput_mib_s{\($labels)} \(.throughput_mib_s)" else null end ])
  + metric("s3pulse_objects_per_s";
      [ if .objects_per_s != null then "s3pulse_objects_per_s{\($labels)} \(.objects_per_s)" else null end ])
  + metric("s3pulse_latency_ms";
      [ if .latency_ms.p50 != null then "s3pulse_latency_ms{\($labels),quantile=\"0.5\"} \(.latency_ms.p50)" else null end,
        if .latency_ms.p90 != null then "s3pulse_latency_ms{\($labels),quantile=\"0.9\"} \(.latency_ms.p90)" else null end,
        if .latency_ms.p99 != null then "s3pulse_latency_ms{\($labels),quantile=\"0.99\"} \(.latency_ms.p99)" else null end ])
  + metric("s3pulse_errors_total";
      [ if .errors != null then "s3pulse_errors_total{\($labels)} \(.errors)" else null end ])
  + metric("s3pulse_last_run_timestamp_seconds";
      [ "s3pulse_last_run_timestamp_seconds{\($labels)} \($ts)" ])
  + metric("s3pulse_last_run_success";
      [ "s3pulse_last_run_success{\($labels)} \(if .success then 1 else 0 end)" ])
  | .[]' "${RESULT_FILE}")"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'DRY_RUN pushgateway request:\nPUT %s\nContent-Type: text/plain; version=0.0.4\n\n%s\n\n' "${PUSH_URL}" "${BODY}"
  exit 0
fi

if printf '%s\n' "${BODY}" | curl --silent --show-error --fail \
    --request PUT \
    --header "Content-Type: text/plain; version=0.0.4" \
    --max-time 15 \
    --data-binary @- \
    "${PUSH_URL}"; then
  log "pushed ${SCENARIO_NAME} to ${PUSH_URL}"
else
  log "push to ${PUSH_URL} failed"
  exit 1
fi
