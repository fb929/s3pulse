# s3pulse runner image: alpine + bash/jq/curl/zstd/flock + the warp binary
# copied from the official MinIO Warp image (multi-stage build).
#
# The official image (both Dockerfile and Dockerfile.release in minio/warp)
# places the statically linked binary at /warp and uses it as ENTRYPOINT.
# The `RUN warp --version` step below fails the build if that path ever changes.

ARG WARP_IMAGE=minio/warp:latest
ARG ALPINE_IMAGE=alpine:3.20

FROM ${WARP_IMAGE} AS warp

FROM ${ALPINE_IMAGE}

# coreutils + gawk: long-form flags for `timeout`, `date`, `sleep`, `od`, `awk`.
# flock: Alpine >= 3.18 ships it as its own package; older releases keep it in
# util-linux-misc; busybox also has a flock applet as a last resort.
RUN apk add --no-cache bash jq curl zstd coreutils gawk ca-certificates tzdata \
    && (apk add --no-cache flock || apk add --no-cache util-linux-misc || true) \
    && command -v flock

COPY --from=warp /warp /usr/local/bin/warp
RUN chmod 0755 /usr/local/bin/warp && warp --version

WORKDIR /app
COPY VERSION scenarios.json /app/
COPY scripts/ /app/scripts/
COPY sinks/ /app/sinks/
RUN chmod 0755 /app/scripts/*.sh /app/sinks/*.sh

ENV S3PULSE_HOME=/app \
    RESULTS_DIR=/results

VOLUME ["/results"]

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
