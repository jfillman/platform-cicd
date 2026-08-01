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
# Build context MUST be the repo root (paths below are repo-root-relative):
#   docker build -f catalog/toolbox/Dockerfile -t ghcr.io/platform-cicd/toolbox:latest .
#
# schemas/cicd.schema.json is baked in here rather than mounted from a ConfigMap, which
# means a schema change requires a toolbox image rebuild + catalog version bump, not a
# silent live update - see docs/cicd-yaml-reference.md for why that's deliberate
# (avoids the "config takes effect asynchronously from some other sync" problem the
# architecture plan explicitly rejected for cicd.yaml itself).

FROM alpine:3.20

ARG OTEL_CLI_VERSION=0.5.0
ARG YQ_VERSION=4.44.3
ARG KUBECTL_VERSION=1.30.4
ARG YAJSV_VERSION=1.4.1

RUN apk add --no-cache bash curl jq git openssl ca-certificates util-linux coreutils

RUN curl -fsSL -o /usr/local/bin/otel-cli \
      "https://github.com/equinix-labs/otel-cli/releases/download/v${OTEL_CLI_VERSION}/otel-cli_${OTEL_CLI_VERSION}_linux_amd64" \
    && chmod +x /usr/local/bin/otel-cli \
    && curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq \
    && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL -o /usr/local/bin/yajsv \
      "https://github.com/neilpa/yajsv/releases/download/v${YAJSV_VERSION}/yajsv.linux.amd64" \
    && chmod +x /usr/local/bin/yajsv

COPY catalog/lib/otel.sh /opt/platform/lib/otel.sh
COPY catalog/lib/cdevents.sh /opt/platform/lib/cdevents.sh
COPY catalog/lib/build-agents.env /opt/platform/lib/build-agents.env
COPY schemas/cicd.schema.json /opt/platform/schemas/cicd.schema.json

# Non-root by default - every catalog Task should run under Pod Security Standards
# "restricted" without needing per-Task overrides.
RUN adduser -D -u 65532 platform
USER 65532

ENV PLATFORM_LIB=/opt/platform/lib
