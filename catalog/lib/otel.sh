#!/usr/bin/env bash
# catalog/lib/otel.sh
#
# Shared span-instrumentation helpers for pipeline step scripts, built on otel-cli
# (github.com/equinix-labs/otel-cli), baked into the toolbox image (see
# catalog/toolbox/Dockerfile). Every catalog Task step sources this file instead of
# shelling out to otel-cli directly, so a version bump only needs a fix here.
#
# NOTE: the exact otel-cli flag names below match its "span background" workflow as
# documented upstream, but MUST be re-verified against whichever otel-cli version gets
# pinned in Phase 0 (see plan's build-sequence item "OTel: prove root-span + traceparent
# threading within a single PipelineRun first") before this is trusted in a real Task.
#
# Contract:
#   - TRACEPARENT (W3C trace context) is threaded through Tekton task params/results,
#     never rediscovered locally - see catalog/stepactions/otel-span-*.yaml.
#   - One flow-root span covers an entire build->test->deploy->release run. Every
#     stage's root span parents directly to the flow root (flat, not nested - stages
#     don't overlap in time, so nesting would misrepresent duration in Tempo).
#   - The flow-root traceparent is what gets carried inside the CDEvent payload across
#     independently-triggered PipelineRuns - see cdevents.sh.

set -euo pipefail

: "${OTEL_EXPORTER_OTLP_ENDPOINT:?OTEL_EXPORTER_OTLP_ENDPOINT must be set (in-cluster OTel Collector)}"

_otel_sockdir() {
  echo "${TEKTON_HOME:-/tekton/home}"
}

# otel_flow_root_start <flow-name>
# Called once, by the first Task of the first stage in a flow (i.e. no incoming
# traceparent param - this is a fresh build triggered by a git push). Starts the root
# span for the whole flow and prints its traceparent on stdout; callers MUST capture
# this into a Tekton result (conventionally named "traceparent").
otel_flow_root_start() {
  local flow_name="$1"
  otel-cli span background \
    --name "${flow_name}" \
    --service "platform-cicd" \
    --sockdir "$(_otel_sockdir)" \
    --tp-print
}

# otel_stage_span_start <stage-name> <flow-traceparent> <chain-id>
# Called once per stage (build/test/deploy/release) by that stage's first Task.
# Parents the stage span directly to the flow root so stages render as siblings
# under one trace instead of falsely nested/overlapping spans.
otel_stage_span_start() {
  local stage_name="$1" flow_traceparent="$2" chain_id="$3"
  otel-cli span background \
    --name "stage:${stage_name}" \
    --service "platform-cicd" \
    --tp-parent "${flow_traceparent}" \
    --attrs "platform.chain_id=${chain_id},platform.stage=${stage_name}" \
    --sockdir "$(_otel_sockdir)" \
    --tp-print
}

# otel_step_span <step-name> -- <command...>
# Wraps a single step's command in its own child span under the current stage span.
# This is what most Task step scripts actually call.
otel_step_span() {
  local step_name="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  otel-cli span exec \
    --name "step:${step_name}" \
    --service "platform-cicd" \
    --sockdir "$(_otel_sockdir)" \
    -- "$@"
}

# otel_span_end <tekton-status>
# Ends the current background span (stage or flow-root). tekton-status is Tekton's own
# aggregate status string (Succeeded/Completed/Failed/None, i.e. the value of
# $(tasks.status) in a Pipeline's finally block) rather than a numeric exit code - this
# is the value every calling Pipeline already has on hand natively, so there's no
# fragile translation step between "how Tekton reports outcome" and "how otel-cli
# reports outcome". Every Task that called otel_flow_root_start or otel_stage_span_start
# MUST have a corresponding finally call to this, or the trace is left dangling.
otel_span_end() {
  local tekton_status="${1:-Succeeded}"
  local status="ok"
  [[ "${tekton_status}" != "Succeeded" && "${tekton_status}" != "Completed" ]] && status="error"
  otel-cli span end --sockdir "$(_otel_sockdir)" --status-code "${status}"
}

# otel_mark_governance_stub <gate-name>
# Tags the current span so Grafana renders this gate as a visually-distinct stub
# rather than a real enforcement result. Every governance-stub Task must call this -
# see docs/governance-stubs.md. This is the direct, deliberate fix for the old
# platform's silently-always-passing `exit 0` gates.
otel_mark_governance_stub() {
  local gate_name="$1"
  otel-cli span event --sockdir "$(_otel_sockdir)" \
    --name "governance.stub" \
    --attrs "governance.gate=${gate_name},governance.stub=true"
}
