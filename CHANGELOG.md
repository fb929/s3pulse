# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-09

### Added

- docker-compose setup running MinIO Warp against an external S3-compatible endpoint.
- `probe` and `load` profiles driven by `scenarios.json` (per-profile overrides).
- Normalized per-scenario result JSON (`throughput_mib_s`, `objects_per_s`, latency p50/p90/p99, errors, success).
- Pluggable sinks: `stub` (stdout + `/results`), `pushgateway` (Prometheus text exposition, HTTP PUT, stable grouping key), `http_json` (POST with retries).
- Interval mode (`RUN_INTERVAL_SECONDS`) with graceful SIGTERM/SIGINT handling and `flock` overlap protection.
- `selftest` compose profile with a local MinIO for end-to-end smoke tests.
- `DRY_RUN` mode for sinks, Makefile targets `up`, `run`, `selftest`, `down`, `lint`.
