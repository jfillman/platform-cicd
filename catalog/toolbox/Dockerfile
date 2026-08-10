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
# gitsign - used by catalog/tasks/verify-commit-signature.yaml to verify a fetched app-repo
# commit's signature/identity, not to sign anything from inside a Task (signing is a
# developer-machine, interactive-OIDC-flow action, see docs/commit-signing.md). Real
# linux_amd64/linux_arm64 asset names confirmed against the actual v0.17.0 release (checked
# live via the GitHub API), not guessed.
#
# ec (Conforma CLI, docs/provenance-policy.md) - used by
# catalog/tasks/verify-image-provenance.yaml. Deliberately the GitHub-release binary
# (github.com/conforma/cli), not the quay.io/enterprise-contract/ec-cli container image -
# that image is amd64-only and genuinely crashes under this node's arm64 emulation with a
# real Go-runtime panic (confirmed live, not assumed), while a real native
# ec_linux_arm64 release asset exists and runs natively.
#
# cosign - also used by verify-image-provenance.yaml, for the actual signature/attestation
# cryptographic verification (ec's own built-in verification needs a TUF-distributed trust
# root; cosign's --ca-roots flag verifies against a local file directly, no TUF needed -
# see that Task's own header comment for the full reasoning).
#
# libxml2-utils (xmllint) - used by build-image.yaml's resolve-build-config step to pull
# the real <version> out of a Maven app's pom.xml for untagged (non-tag-triggered) builds,
# the same source-of-truth pattern the old cd-pipelines platform's task-get-tag.yaml used
# (package.json's version needs only jq, already present above).
#
# Build context MUST be the repo root (paths below are repo-root-relative):
#   docker build -f catalog/toolbox/Dockerfile -t ghcr.io/jfillman/platform-cicd-toolbox:latest .
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
ARG GITSIGN_VERSION=0.17.0
ARG EC_VERSION=0.9.88
ARG COSIGN_VERSION=3.1.2
ARG TRIVY_VERSION=0.73.0

RUN apk add --no-cache bash curl jq git openssl ca-certificates util-linux coreutils libxml2-utils

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
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL -o /usr/local/bin/gitsign \
      "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/gitsign_${GITSIGN_VERSION}_linux_${ARCH}" \
    && chmod +x /usr/local/bin/gitsign \
    && curl -fsSL -o /usr/local/bin/ec \
      "https://github.com/conforma/cli/releases/download/v${EC_VERSION}/ec_linux_${ARCH}" \
    && chmod +x /usr/local/bin/ec \
    && curl -fsSL -o /usr/local/bin/cosign \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${ARCH}" \
    && chmod +x /usr/local/bin/cosign \
    && case "$(uname -m)" in x86_64) TRIVY_ARCH=64bit ;; aarch64|arm64) TRIVY_ARCH=ARM64 ;; esac \
    && curl -fsSL -o /tmp/trivy.tar.gz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" \
    && tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy \
    && chmod +x /usr/local/bin/trivy \
    && rm /tmp/trivy.tar.gz

COPY --from=yajsv-build /go/bin/yajsv /usr/local/bin/yajsv

COPY catalog/lib/otel.sh /opt/platform/lib/otel.sh
COPY catalog/lib/cdevents.sh /opt/platform/lib/cdevents.sh
COPY catalog/lib/github-app.sh /opt/platform/lib/github-app.sh
COPY catalog/lib/build-agents.env /opt/platform/lib/build-agents.env
COPY schemas/cicd.schema.json /opt/platform/schemas/cicd.schema.json

# Onboarding boilerplate (Phase 3 item 7's PaC-delivery mechanism - see
# catalog/tasks/deliver-onboarding-files.yaml and docs/onboarding.md) used to be baked in
# here the same way catalog/lib and the schema still are - moved to a ConfigMap
# (charts/platform-cicd-app/templates/configmaps/onboarding-templates.yaml, one copy per
# Application, sourced from charts/platform-cicd-app/files/onboarding-templates/)
# instead, deliberately the OPPOSITE choice from schema.json below. Baking these in
# meant a template edit silently depended on an image rebuild+push AND on
# :latest/IfNotPresent actually re-pulling on every node, the same staleness class that
# once left a stale image reference live in the stalled-pipeline-detector CronJob for
# days. A ConfigMap ties a template edit to a real `helm upgrade` instead - of the APP
# chart, per Application, not a single shared catalog-chart release (a first version
# tried a single shared ConfigMap in the catalog chart, which would have needed a
# cross-namespace kubectl read plus new RBAC to actually work, since a Pod can only
# volume-mount a ConfigMap from its own namespace - dropped in favor of this simpler,
# per-Application shape, consistent with how every other per-tenant resource in this
# platform already works). schemas/cicd.schema.json below stays baked in on purpose -
# see its own comment for why forcing an explicit rebuild is the right call THERE.

# Non-root by default - every catalog Task should run under Pod Security Standards
# "restricted" without needing per-Task overrides.
RUN adduser -D -u 65532 platform
USER 65532

ENV PLATFORM_LIB=/opt/platform/lib
