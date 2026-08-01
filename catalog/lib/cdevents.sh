#!/usr/bin/env bash
# catalog/lib/cdevents.sh
#
# Emits CDEvents (https://cdevents.dev) to the shared internal broker, used to chain
# independently-triggered PipelineRuns (build -> test -> deploy -> release). This is
# the only place the platform.traceparent / chainId fields are assembled - kept as two
# distinct fields on purpose: chainId is CDEvents' own causal-sequence correlator,
# platform.traceparent is the separate W3C trace-context used to stitch one Tempo trace
# across the whole flow. See docs/chaining.md and docs/tracing.md.
#
# Auth: the caller's own audience-bound projected ServiceAccount token (mounted by the
# pipeline pod's ServiceAccount, see platform/broker/manifests/projected-token-volume.yaml)
# is sent as a bearer token. The broker verifies it via the Kubernetes TokenReview API -
# there is no platform-minted credential anywhere in this path.

set -euo pipefail

: "${CDEVENTS_BROKER_URL:?CDEVENTS_BROKER_URL must be set (in-cluster shared EventListener address)}"
: "${NAMESPACE:?NAMESPACE must be set (tenant namespace, injected via downward API)}"
: "${TEKTON_PIPELINE_RUN:?TEKTON_PIPELINE_RUN must be set (injected via downward API/params)}"

_BROKER_TOKEN_PATH="/var/run/secrets/platform/broker-token"

# cdevent_send <event-type> <subject-id> <subject-content-json>
#   event-type            e.g. dev.cdevents.artifact.published.0.3.0
#   subject-id             the emitting PipelineRun's own name
#   subject-content-json    a JSON object merged into subject.content (single-quoted JSON)
#
# Idempotency: the CDEvents "id" is deterministically derived from the PipelineRun name
# + event-type, not randomly generated, so at-least-once delivery from a retried step
# produces the same event id every time. The next-stage Trigger uses this id to name the
# PipelineRun it creates, so redelivery is a harmless no-op instead of a duplicate run.
cdevent_send() {
  local event_type="$1" subject_id="$2" subject_content_json="$3"

  local sa_token
  sa_token="$(cat "${_BROKER_TOKEN_PATH}")"

  local event_id
  event_id="$(printf '%s' "${TEKTON_PIPELINE_RUN}:${event_type}" | sha256sum | cut -d' ' -f1)"

  local payload
  payload="$(jq -n \
    --arg id "${event_id}" \
    --arg type "${event_type}" \
    --arg source "/platform-cicd/${NAMESPACE}/${TEKTON_PIPELINE_RUN}" \
    --arg subjectId "${subject_id}" \
    --arg chainId "${PLATFORM_CHAIN_ID:?PLATFORM_CHAIN_ID must be set - propagated from the triggering event, or generated at flow start}" \
    --arg traceparent "${PLATFORM_TRACEPARENT:?PLATFORM_TRACEPARENT must be set - see otel.sh}" \
    --argjson content "${subject_content_json}" \
    '{
      context: {
        version: "0.4.1",
        id: $id,
        source: $source,
        type: $type,
        timestamp: (now | todate),
        chainId: $chainId
      },
      subject: {
        id: $subjectId,
        source: $source,
        type: "pipelinerun",
        content: $content
      },
      customData: {
        platform: { traceparent: $traceparent }
      },
      customDataContentType: "application/json"
    }')"

  curl --fail --silent --show-error \
    --retry 3 --retry-connrefused --max-time 10 \
    -X POST "${CDEVENTS_BROKER_URL}" \
    -H "Authorization: Bearer ${sa_token}" \
    -H "Content-Type: application/cloudevents+json" \
    -d "${payload}"
}
