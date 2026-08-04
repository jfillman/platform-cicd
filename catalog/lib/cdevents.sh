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

# cdevent_send <event-type> <subject-type> <subject-id> <subject-content-json>
#   event-type            e.g. dev.cdevents.artifact.published.0.3.0
#   subject-type           the CDEvents subject type this event's context.type implies -
#                           e.g. "artifact" for artifact.published, "pipelineRun" for
#                           pipelinerun.started/finished. CamelCase for multi-word subject
#                           names (pipelineRun, taskRun, testCaseRun), lowercase for
#                           single-word ones (artifact, service, change, build) - matches
#                           the CDEvents spec's own subject-name casing convention. There
#                           is no derivation from event-type alone worth trusting (the
#                           event-type segment is always lowercase regardless), so this is
#                           a required, explicit argument, not inferred.
#   subject-id             the emitting PipelineRun's own name
#   subject-content-json    a JSON object merged into subject.content (single-quoted JSON)
#
# Idempotency: the CDEvents "id" is deterministically derived from the PipelineRun name
# + event-type, not randomly generated, so at-least-once delivery from a retried step
# produces the same event id every time. The next-stage Trigger uses this id to name the
# PipelineRun it creates, so redelivery is a harmless no-op instead of a duplicate run.
cdevent_send() {
  local event_type="$1" subject_type="$2" subject_id="$3" subject_content_json="$4"

  local sa_token
  sa_token="$(cat "${_BROKER_TOKEN_PATH}")"

  # Truncated to 20 hex chars (80 bits - collision odds are irrelevant at this
  # volume): the TriggerTemplates build PipelineRun names as "test-$(body.context.id)"
  # / "deploy-$(body.context.id)", and Kubernetes resource names cap at 63 characters.
  # A full sha256sum (64 hex chars) blew that limit outright - "test-" plus the full
  # hash is 69 characters - and the resulting PipelineRun silently never got created
  # (caught live via the EventListener's own logs: the Trigger matched and resolved
  # correctly, admission just rejected the name it built).
  local event_id
  event_id="$(printf '%s' "${TEKTON_PIPELINE_RUN}:${event_type}" | sha256sum | cut -d' ' -f1 | cut -c1-20)"

  local payload
  payload="$(jq -n \
    --arg id "${event_id}" \
    --arg type "${event_type}" \
    --arg source "/platform-cicd/${NAMESPACE}/${TEKTON_PIPELINE_RUN}" \
    --arg subjectType "${subject_type}" \
    --arg subjectId "${subject_id}" \
    --arg chainId "${PLATFORM_CHAIN_ID:?PLATFORM_CHAIN_ID must be set - propagated from the triggering event, or generated at flow start}" \
    --arg traceparent "${PLATFORM_TRACEPARENT:?PLATFORM_TRACEPARENT must be set - see otel.sh}" \
    --arg flowStartTime "${PLATFORM_FLOW_START_TIME:?PLATFORM_FLOW_START_TIME must be set - propagated from the triggering event, or set at flow start (see otel_flow_root_begin in otel.sh)}" \
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
        type: $subjectType,
        content: $content
      },
      customData: {
        platform: { traceparent: $traceparent, flow_start_time: $flowStartTime }
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

# cdevents_map_outcome <tekton-status>
#   Maps a Tekton PipelineRun's real status.conditions[].reason value (confirmed against
#   Tekton's own docs: Succeeded, Completed, Failed, Cancelled, PipelineRunTimeout, plus
#   other less common error reasons) to CDEvents' pipelineRun/taskRun "outcome" enum
#   (success/failure/cancel/error - see core.md in the cdevents/spec repo). Used by
#   send-cdevent.yaml's optional tekton-status param, not called directly by pipelines -
#   see docs/chaining.md.
cdevents_map_outcome() {
  case "$1" in
    Succeeded|Completed) echo "success" ;;
    Failed) echo "failure" ;;
    Cancelled) echo "cancel" ;;
    *) echo "error" ;;
  esac
}
