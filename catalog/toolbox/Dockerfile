# catalog/toolbox/Dockerfile
#
# Shared base image for every catalog Task step. All step logic is bash (per platform
# requirement) - this image exists so common tools/libs are versioned and patched in
# exactly one place instead of duplicated per Task, the same problem that scattered
# bespoke bash+curl+jq snippets across every task-*.yaml in the old platform.
#
# Pinned tool versions are intentionally explicit build args, not "latest" - a shared
# image used by every tenant's pipelines is a supply-chain-sensitive artifact.
#
# Architecture-aware by necessity, not just care: this gets built and run on kind-observe's
# arm64 node, and every download below is resolved via `uname -m` at build time rather
# than hardcoded to amd64 - an earlier version of this file hardcoded linux_amd64
# unconditionally, which would have baked unrunnable binaries into an image meant to run
# on arm64 (exec format error at runtime, not a build-time failure - the kind of bug that
# only surfaces once a real pipeline actually tries to run a step).
#
# yajsv (JSON Schema validator, used by validate-cicd-config) doesn't publish a linux/arm64
# binary at all (checked against its actual release assets, v1.4.1 - only linux/amd64 and
# linux/386, plus darwin/arm64) - built from source in a Go stage instead of downloaded.
#
# Build context MUST be the repo root (paths below are repo-root-relative):
#   docker build -f catalog/toolbox/Dockerfile -t ghcr.io/platform-cicd/toolbox:latest .
#
# schemas/cicd.schema.json is baked in here rather than mounted from a ConfigMap, which
# means a schema change requires a toolbox image rebuild + catalog version bump, not a
# silent live update - see docs/cicd-yaml-reference.md for why that's deliberate
# (avoids the "config takes effect asynchronously from some other sync" problem the
# architecture plan explicitly rejected for cicd.yaml itself).

FROM golang:1.22-alpine AS yajsv-build
ARG YAJSV_VERSION=1.4.1
RUN CGO_ENABLED=0 go install "github.com/neilpa/yajsv@v${YAJSV_VERSION}"

FROM alpine:3.20

ARG OTEL_CLI_VERSION=0.4.5
ARG YQ_VERSION=4.44.3
ARG KUBECTL_VERSION=1.30.4

RUN apk add --no-cache bash curl jq git openssl ca-certificates util-linux coreutils

RUN set -euo pipefail; \
    case "$(uname -m)" in \
      x86_64) ARCH=amd64 ;; \
      aarch64|arm64) ARCH=arm64 ;; \
      *) echo "unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/otel-cli.tar.gz \
      "https://github.com/equinix-labs/otel-cli/releases/download/v${OTEL_CLI_VERSION}/otel-cli_${OTEL_CLI_VERSION}_linux_${ARCH}.tar.gz" \
    && tar -xzf /tmp/otel-cli.tar.gz -C /usr/local/bin otel-cli \
    && chmod +x /usr/local/bin/otel-cli \
    && rm /tmp/otel-cli.tar.gz \
    && curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
    && chmod +x /usr/local/bin/yq \
    && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl

COPY --from=yajsv-build /go/bin/yajsv /usr/local/bin/yajsv

COPY catalog/lib/otel.sh /opt/platform/lib/otel.sh
COPY catalog/lib/cdevents.sh /opt/platform/lib/cdevents.sh
COPY catalog/lib/build-agents.env /opt/platform/lib/build-agents.env
COPY schemas/cicd.schema.json /opt/platform/schemas/cicd.schema.json

# Non-root by default - every catalog Task should run under Pod Security Standards
# "restricted" without needing per-Task overrides.
RUN adduser -D -u 65532 platform
USER 65532

ENV PLATFORM_LIB=/opt/platform/lib
