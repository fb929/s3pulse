# s3pulse

Runs [MinIO Warp](https://github.com/minio/warp) benchmarks against an **external S3-compatible endpoint** (self-hosted or third-party object store, not AWS S3) from a docker-compose setup, normalizes the results into one JSON per scenario and ships them to a pluggable sink. The same pipeline serves two purposes:

- `probe` profile: lightweight, safe to run every few minutes for continuous monitoring.
- `load` profile: full scenario set with higher concurrency and duration for load testing.

Stack: bash + jq + curl + warp inside an Alpine image. No Python, no frameworks.

## Quick start (5 steps)

1. Copy the config and set the endpoint and credentials (dedicated bucket!):
   ```bash
   cp .env.example .env
   # edit .env: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET
   ```
2. Build the runner image (copies the `warp` binary from `minio/warp`):
   ```bash
   make build
   ```
3. Smoke-test the whole pipeline against a throwaway local SeaweedFS S3 server (no real storage touched):
   ```bash
   make selftest
   ```
4. Run the probe profile against the real endpoint once:
   ```bash
   make run                # PROFILE from .env (probe by default)
   make run PROFILE=load   # override .env for this run
   ```
5. Pick up the results (bind-mounted to `./results` by default, `RESULTS_PATH` in `.env`):
   ```bash
   ls results/latest && cat results/latest/probe-put_small.json
   ```

### Point it at a real S3-compatible endpoint

```bash
cat > .env <<'EOF'
S3_ENDPOINT=s3.example.internal:9000   # host:port, no scheme
S3_ACCESS_KEY=AKIA...
S3_SECRET_KEY=...
S3_TLS=true                            # https
S3_TLS_INSECURE=true                   # only for self-signed certificates
S3_REGION=us-east-1                    # most stores ignore it but require a value
S3_BUCKET=s3pulse                      # DEDICATED bucket, it is wiped every run
S3_LOOKUP=path                         # path-style addressing (virtual-host style rarely works)
PROFILE=probe
RUN_LABEL=prod-s3-eu
SINK_TYPE=stub
EOF
make build
make run
```

Verify the warp binary and its flags inside the built image (never rely on memory):

```bash
docker compose run --rm --entrypoint sh s3pulse-runner -c 'command -v warp && warp --version && warp put --help && warp analyze --help'
```

## Configuration

All settings come from `.env` (documented in `.env.example`) and reach the container via `docker-compose.yml`.

| Variable | Default | Description |
|---|---|---|
| `S3_ENDPOINT` | required | `host:port`, no scheme. Passed to warp as `WARP_HOST`. |
| `S3_ACCESS_KEY` | required | Passed as `WARP_ACCESS_KEY` (env only, never a CLI argument). |
| `S3_SECRET_KEY` | required | Passed as `WARP_SECRET_KEY` (env only, never logged). |
| `S3_TLS` | `false` | `true` = https. Passed as `WARP_TLS`. |
| `S3_TLS_INSECURE` | `false` | `true` adds `warp --insecure` (skip certificate verification). |
| `S3_REGION` | `us-east-1` | Passed as `WARP_REGION`. Many stores ignore it but need some value. |
| `S3_BUCKET` | `s3pulse` | Dedicated bucket. **warp deletes everything in it before and after each scenario.** |
| `S3_LOOKUP` | `path` | `path` or `dns`, passed as `warp --lookup`. Keep `path` for most S3-compatible stores. |
| `PROFILE` | `probe` | `probe` or `load`. Also `make run PROFILE=load`. |
| `DEFAULT_DURATION` | `30` | Seconds; used when a scenario does not set `duration`. |
| `DEFAULT_CONCURRENCY` | `4` | Used when a scenario does not set `concurrent`. |
| `SINK_TYPE` | `stub` | `stub`, `pushgateway` or `http_json`. |
| `SINK_URL` | empty | Pushgateway base URL (`http://pushgateway:9091`) or full POST URL for `http_json`. |
| `SINK_HTTP_BEARER_TOKEN` | empty | Optional `Authorization: Bearer` for `http_json`. |
| `RUN_LABEL` | `default` | Stable label for the target (e.g. `prod-s3-eu`); Prometheus `instance` label. `[A-Za-z0-9._-]` only. |
| `RUN_INTERVAL_SECONDS` | empty | If set, loop forever and sleep N seconds after each full run. Empty = run once and exit. |
| `DRY_RUN` | `false` | Sinks print the exact request (URL, headers without secrets, body) instead of sending it. |
| `RESULTS_PATH` | `./results` | Host directory bind-mounted at `/results` (raw benchdata, normalized JSON, logs). |
| `WARP_EXTRA_ARGS` | empty | Extra warp flags appended to every scenario, e.g. `--disable-multipart --md5`. |
| `WARP_IMAGE` | `minio/warp:latest` | Source image for the warp binary (build arg). Pin a tag for reproducible numbers. |
| `SELFTEST_S3_IMAGE` | `chrislusf/seaweedfs:latest` | S3 server image for the selftest profile (MinIO images are no longer anonymously pullable). |
| `SELFTEST_DURATION` | `5` | Scenario duration used by `make selftest`. |

### Profiles and scenarios

`scenarios.json` lists the scenarios. Each entry has `name`, `profiles`, `command` (`put|get|mixed|delete|list|stat|multipart`), `obj_size`, `concurrent`, `duration` (seconds), `objects`, `extra_args` and an optional `overrides` map keyed by profile. Resolution order per field: `.env` defaults (`DEFAULT_DURATION`, `DEFAULT_CONCURRENCY`) < scenario value < `overrides.<PROFILE>` value. `null` means "use the default".

Shipped scenarios:

| Scenario | Profiles | Command | Object size | probe (concurrency / duration) | load (concurrency / duration) |
|---|---|---|---|---|---|
| `put_small` | probe, load | put | 4KiB | 4 / 30s | 32 / 120s |
| `get_medium` | probe, load | get | 1MiB | 4 / 30s, 50 objects | 16 / 120s, 1000 objects |
| `list_1k` | probe, load | list | 1KiB x 1000 objects | 2 / 30s | 8 / 60s |
| `put_medium` | load | put | 1MiB | - | 16 / 120s |
| `put_large` | load | put | 64MiB | - | 4 / 120s |
| `mixed_medium` | load | mixed | 1MiB, 1000 objects, warp default distribution | - | 16 / 120s |

The probe profile runs three 30s scenarios plus warp's prepare/cleanup phases and finishes in well under 2 minutes on a healthy endpoint (about 100-110s).

### How warp is invoked

Per scenario (flags verified against the warp source, `cli/flags.go`, `cli/benchmark.go`, `cli/analyze.go`):

```
WARP_HOST=<S3_ENDPOINT> WARP_ACCESS_KEY=... WARP_SECRET_KEY=... WARP_REGION=<S3_REGION> WARP_TLS=<S3_TLS> \
warp <command> --bucket <S3_BUCKET> --lookup <S3_LOOKUP> --concurrent N --duration Ns \
     --obj.size <size> [--objects N] --benchdata /results/<run_id>/<scenario> --no-color --quiet [--insecure] [extra_args]
warp analyze --json --no-color --quiet /results/<run_id>/<scenario>.json.zst
```

`--noclear` is never passed, so warp wipes the bucket before and after every scenario; that is why the bucket must be dedicated to s3pulse. Each warp invocation is wrapped in `timeout` (3 x duration + 180s) so a hung endpoint cannot block the loop forever.

S3-compatibility notes from `warp --help`: `--lookup path` forces path-style addressing (default here); `--insecure` disables certificate verification; `--region` is passed through as-is; `--disable-multipart` and `--md5` exist for stores that have trouble with multipart uploads or require `Content-MD5`; `--disable-sha256-payload` avoids client-side SHA-256 payload hashing; `--checksum` (CRC32/CRC32C/CRC64NVME/SHA...) is **not** used because many S3-compatible stores do not implement additional checksums. Put such switches into `WARP_EXTRA_ARGS` or a scenario's `extra_args` as needed. No AWS-only features (checksums, versioning, lifecycle) are required.

## Results

Everything lands in `RESULTS_PATH` on the host (default `./results`, bind-mounted at `/results`; a named volume is not used because on macOS it would be hidden inside the Docker Desktop VM):

```
/results/<run_id>/<scenario>.json          normalized result
/results/<run_id>/<scenario>.json.zst      raw warp benchdata
/results/<run_id>/<scenario>.analysis.json full `warp analyze --json` output
/results/<run_id>/<scenario>.warp.log      warp stdout/stderr
/results/<run_id>/summary.tsv              per-run summary table
/results/latest/<profile>-<scenario>.json  latest result per scenario (stub sink)
```

Normalized result:

```json
{
  "run_id": "20261009T153000Z-a1b2",
  "run_label": "prod-s3-eu",
  "profile": "probe",
  "timestamp": "2026-10-09T15:30:00Z",
  "version": "0.1.0",
  "scenario": "put_small",
  "operation": "PUT",
  "throughput_mib_s": 12.345,
  "objects_per_s": 3160.4,
  "latency_ms": { "p50": 1.21, "p90": 2.03, "p99": 5.87 },
  "errors": 0,
  "duration_s": 30,
  "concurrent": 4,
  "obj_size": "4KiB",
  "success": true
}
```

Rules:

- `success` is `true` only if warp exited 0, `warp analyze` produced parseable JSON **and** `errors == 0`. Anything else, including warp not starting at all, yields `success: false`.
- Missing fields are `null`, never a crash. A scenario that fails to run still emits a result (null metrics, `success: false`) so monitoring can alert on it.
- `throughput_mib_s` = bytes / measured seconds / 2^20; `objects_per_s` = objects / measured seconds, both taken from `by_op_type.<OP>.throughput` (`mixed` uses `total`).
- `latency_ms` percentiles come from warp's per-client 10-second request segments (`single_sized_requests.dur_median_millis`, `dur_90_millis`, `dur_99_millis`) combined with a request-weighted mean across segments. This is an approximation of the true run-wide percentile.
- `operation` is `PUT|GET|LIST|STAT|DELETE|MIXED`.
- Exit code of a single run is non-zero if any scenario has `success: false`; a sink failure is logged but never fails the run or aborts remaining scenarios.

## Sinks

| `SINK_TYPE` | What it does |
|---|---|
| `stub` (default) | Prints the JSON to stdout and writes `/results/latest/<profile>-<scenario>.json`. Zero dependencies. |
| `pushgateway` | `PUT <SINK_URL>/metrics/job/s3pulse/instance/<RUN_LABEL>/profile/<profile>/scenario/<scenario>` in Prometheus text format. |
| `http_json` | `POST <SINK_URL>` with `Content-Type: application/json`, 3 attempts with 1s/2s/4s backoff, soft failure. |

Pushgateway metrics (all carry an `operation` label; null values are skipped, never pushed as 0):

```
s3pulse_throughput_mib_s{operation="PUT"}
s3pulse_objects_per_s{operation="PUT"}
s3pulse_latency_ms{operation="PUT",quantile="0.5|0.9|0.99"}
s3pulse_errors_total{operation="PUT"}
s3pulse_last_run_timestamp_seconds{operation="PUT"}
s3pulse_last_run_success{operation="PUT"}   # 1 or 0
```

The grouping key `job=s3pulse, instance=<RUN_LABEL>, profile, scenario` is stable, so each run overwrites the previous push for the same scenario and the series stay continuous. `run_id` is not a label (it only lives in the JSON). Preview any sink without sending: `DRY_RUN=true make run`.

## Using as monitoring

1. Set in `.env`: `PROFILE=probe`, `RUN_INTERVAL_SECONDS=300`, `SINK_TYPE=pushgateway`, `SINK_URL=http://pushgateway:9091`, `RUN_LABEL=prod-s3-eu`.
2. Start with the monitoring override, which adds `restart: unless-stopped` and the interval:
   ```bash
   docker compose --file docker-compose.yml --file docker-compose.monitoring.yml up --detach
   docker compose logs --follow s3pulse-runner
   ```
3. Stop gracefully (the current warp run is terminated with SIGTERM so it can clean the bucket, then the runner exits 0):
   ```bash
   docker compose --file docker-compose.yml --file docker-compose.monitoring.yml down
   ```

Overlapping runs are impossible: scenarios run sequentially in one loop, a new iteration starts only after the previous one finished and slept, and `/results/.s3pulse.lock` (`flock`) refuses a second runner on the same volume.

Example Prometheus alerts:

```yaml
groups:
  - name: s3pulse
    rules:
      - alert: S3PulseStale
        expr: time() - s3pulse_last_run_timestamp_seconds{job="s3pulse"} > 900
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "s3pulse {{ $labels.instance }}/{{ $labels.scenario }} has not reported for 15m"
      - alert: S3PulseScenarioFailed
        expr: s3pulse_last_run_success{job="s3pulse"} == 0
        for: 10m
        labels: { severity: critical }
        annotations:
          summary: "s3pulse scenario {{ $labels.scenario }} failing on {{ $labels.instance }}"
      - alert: S3PulseSlowPut
        expr: s3pulse_latency_ms{job="s3pulse",scenario="put_small",quantile="0.99"} > 500
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "p99 PUT latency above 500ms on {{ $labels.instance }}"
```

Remember to set `honor_labels: true` on the Pushgateway scrape job so `instance` keeps the `RUN_LABEL` value.

## Adding a scenario

Append an object to `scenarios.json`:

```json
{
  "name": "stat_small",
  "profiles": ["load"],
  "command": "stat",
  "obj_size": "4KiB",
  "concurrent": 16,
  "duration": 60,
  "objects": 5000,
  "extra_args": ["--noprefix"],
  "overrides": { "probe": { "concurrent": 2, "duration": null } }
}
```

`extra_args` are passed to warp verbatim (long-form flags only). Validate with `jq . scenarios.json` and `make lint`, then rebuild (`make build`) since the file is baked into the image.

## Adding a sink

1. Create `sinks/<name>.sh` (`#!/usr/bin/env bash`, `set -euo pipefail`). It receives the normalized JSON path as `$1`, reads `SINK_URL`/`DRY_RUN` from the environment, must print the exact request when `DRY_RUN=true`, must never print secrets, and exits non-zero on failure (the runner logs and continues).
2. Add the name to the `case` in `scripts/sink.sh` and `scripts/entrypoint.sh`, to `SCRIPTS` in the `Makefile`, document it here and bump `VERSION`/`CHANGELOG.md`.

## Makefile targets

`make build`, `make run [PROFILE=load]`, `make up`, `make selftest [SELFTEST_DURATION=5]`, `make down`, `make lint` (shellcheck, `set -euo pipefail` check, `docker compose config` for all three variants, short-flag grep), `make clean-results` (wipes `RESULTS_PATH`).

## Assumptions

- The target is an S3-compatible store (MinIO, Ceph RGW, SeaweedFS, Garage, Wasabi, ...), reached as `host:port`; path-style addressing and `us-east-1` work by default; no AWS-only checksums, versioning or lifecycle are required.
- `S3_BUCKET` exists or the credentials may create it (warp creates it if missing), and it is dedicated to s3pulse because warp wipes it before and after each scenario.
- The `warp` binary lives at `/warp` in the official `minio/warp` image (true for both `Dockerfile` and `Dockerfile.release` in the warp repository); the image build fails on `warp --version` if that path changes. Flags and the `warp analyze --json` structure were verified against the warp source at v1.8.2 (`aggregate.Realtime`); re-check with `warp --help` after bumping `WARP_IMAGE`.
- Latency percentiles are a request-weighted mean of warp's per-segment percentiles, not an exact run-wide percentile.
- `mixed` scenarios report totals across GET/PUT/STAT/DELETE under `operation: MIXED`.
- Per-profile tuning lives in `scenarios.json` `overrides.<profile>`; `.env` `DEFAULT_*` apply to scenarios that leave a field `null`.
- A single runner per results directory; interval mode is meant to be started through `docker-compose.monitoring.yml`.
- A warp run is killed after `3 x duration + 180s`, producing a failed result instead of hanging the loop.
- The `http_json` receiver accepts any 2xx; authentication, if any, is a bearer token (`SINK_HTTP_BEARER_TOKEN`).
- Label values (`RUN_LABEL`, profile, scenario) are restricted to `[A-Za-z0-9._-]` so they can be used in the Pushgateway URL path without encoding.
- `docker compose config` prints interpolated secrets; `make lint` uses `--quiet` so nothing is printed.
