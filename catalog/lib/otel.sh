#!/usr/bin/env bash
# catalog/lib/otel.sh
#
# Shared span-instrumentation helpers for pipeline step scripts, built on otel-cli
# (github.com/equinix-labs/otel-cli), baked into the toolbox image (see
# catalog/toolbox/Dockerfile). Every catalog Task step sources this file instead of
# shelling out to otel-cli directly, so a version bump only needs a fix here.
#
# Stateless by design: every span this file emits is sent via ONE bare `otel-cli span`
# (or `otel-cli exec`) call carrying explicit trace-id/span-id/parent-span-id/timestamps,
# never via otel-cli's `span background` + separate `span end`/`span event` daemon-socket
# workflow. An earlier version of this file used that daemon workflow to let a span start
# in one Tekton Task and end in a later one (needed for flow-root/stage spans, which span
# multiple Tasks and even multiple independently-triggered PipelineRuns) - it never
# worked, because each Tekton Task runs in its own Pod, and otel-cli's background daemon
# listens on a Unix socket local to whichever Pod started it: a Task in a different Pod
# calling `span end`/`span event` against that socket path can never reach it. Every span
# sent through that path showed an exact 1.00s duration and a `timeout` event (verified
# live, against real trace data in Tempo) - otel-cli's own default --timeout (1s) fired
# because the real "end" call never arrived. See docs/tracing.md.
#
# The fix: split "begin" (mint identifiers + a start timestamp, thread them through
# Tekton results/CDEvents exactly like traceparent already was) from "send" (one
# stateless otel-cli call with explicit --start/--end/--force-*-id flags, safe from any
# Task/Pod, run only once the real end time is known - see otel_span_send).
#
# Contract:
#   - TRACEPARENT (W3C trace context) is threaded through Tekton task params/results,
#     never rediscovered locally - see catalog/stepactions/otel-*.yaml.
#   - One flow-root span covers an entire build->test->deploy->release run. Every
#     stage's span parents directly to the flow root (flat, not nested - stages don't
#     overlap in time, so nesting would misrepresent duration).
#   - The flow-root traceparent is what gets carried inside the CDEvent payload across
#     independently-triggered PipelineRuns - see cdevents.sh.

set -euo pipefail

otel_now() {
  date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

otel_traceparent_trace_id() {
  cut -d- -f2 <<< "$1"
}

otel_traceparent_span_id() {
  cut -d- -f3 <<< "$1"
}

# otel_flow_root_begin
# Mints identifiers + a start timestamp for a NEW flow-root span, without sending
# anything yet - see the file header. Prints "<traceparent> <start-time>". Called
# exactly once, by build (the only stage that's always a fresh flow start).
otel_flow_root_begin() {
  local trace_id span_id
  trace_id="$(openssl rand -hex 16)"
  span_id="$(openssl rand -hex 8)"
  printf '00-%s-%s-01 %s\n' "${trace_id}" "${span_id}" "$(otel_now)"
}

# otel_stage_span_begin <flow-traceparent>
# Mints a span id + start timestamp for one stage's own span - a sibling of the
# flow-root, reusing the flow's trace id so it lands in the same trace. Prints
# "<span-id> <start-time>".
otel_stage_span_begin() {
  local flow_traceparent="$1"
  # Fail fast here if the incoming traceparent is malformed, rather than only at
  # send time (in a later, possibly much-later, Task).
  otel_traceparent_trace_id "${flow_traceparent}" >/dev/null
  printf '%s %s\n' "$(openssl rand -hex 8)" "$(otel_now)"
}

# _otel_cli_send <args...>
# Shared retry wrapper around a one-shot `otel-cli span` call - used by otel_span_send
# and otel_task_span_send, both of which mint their span's identity/timestamps up
# front and send them in a single explicit-id, explicit-timestamp call, making a retry
# of the exact same call safe (never a duplicate side effect, just the same span
# re-offered to the collector). Real bug, found live 2026-08-12: a bare `otel-cli
# span ...` call has no retry AND (without --fail, which nothing here passed) exits 0
# even when it can't reach the collector at all (confirmed by pointing it at an
# unroutable address) - so a transient hiccup either silently dropped the span with no
# error, or - when otel-cli's own default 1s --timeout wasn't enough under real load
# (confirmed live: failed during a burst of 8 concurrent governance-check
# PipelineRuns) - failed the whole calling TaskRun outright with no retry, which is
# what actually broke a real release stage's trace. --fail makes both failure modes
# surface as a real exit code; --timeout 5s gives real sends more room than otel-cli's
# default under load; 3 attempts with a short backoff covers a one-off blip without
# masking a genuinely down collector for long.
_otel_cli_send() {
  local attempt
  for attempt in 1 2 3; do
    if otel-cli "$@" --fail --timeout 5s; then
      return 0
    fi
    [[ "${attempt}" -lt 3 ]] && sleep 2
  done
  echo "otel-cli span send failed after 3 attempts (collector unreachable or rejecting spans) - continuing, not failing the pipeline over lost trace data" >&2
  return 0
}

# otel_span_send <name> <flow-traceparent> <span-id> <start-time> <end-time> <tekton-status> [attrs]
# The only function here that actually talks to the collector for flow-root/stage
# spans - one stateless otel-cli call, safe from any Task/Pod. tekton-status is
# Tekton's own aggregate status string ($(tasks.status) in a Pipeline's finally
# block); translated to an OTel status code here so callers never need their own
# translation step.
#
# <span-id> empty means "this call ends the flow-root span itself": reuse the span
# id already embedded in <flow-traceparent>, send with no parent. Non-empty means
# "this is one stage's own span" (minted by otel_stage_span_begin):
# <flow-traceparent>'s span id becomes this span's *parent* instead.
otel_span_send() {
  : "${OTEL_EXPORTER_OTLP_ENDPOINT:?OTEL_EXPORTER_OTLP_ENDPOINT must be set (in-cluster OTel Collector)}"
  local name="$1" flow_traceparent="$2" span_id="$3" start_time="$4" end_time="$5" tekton_status="$6"
  local attrs="${7:-}"
  local trace_id flow_root_span_id parent_span_id
  trace_id="$(otel_traceparent_trace_id "${flow_traceparent}")"
  flow_root_span_id="$(otel_traceparent_span_id "${flow_traceparent}")"
  if [[ -z "${span_id}" ]]; then
    span_id="${flow_root_span_id}"
    parent_span_id=""
  else
    parent_span_id="${flow_root_span_id}"
  fi
  local status_code="ok"
  [[ "${tekton_status}" != "Succeeded" && "${tekton_status}" != "Completed" ]] && status_code="error"
  local -a args=(
    span --service "platform-cicd" --name "${name}"
    --force-trace-id "${trace_id}" --force-span-id "${span_id}"
    --start "${start_time}" --end "${end_time}"
    --status-code "${status_code}"
  )
  [[ -n "${parent_span_id}" ]] && args+=(--force-parent-span-id "${parent_span_id}")
  [[ -n "${attrs}" ]] && args+=(--attrs "${attrs}")
  _otel_cli_send "${args[@]}"
}

# otel_task_span_send <name> <flow-traceparent> <parent-span-id> <start-time> <end-time> <tekton-status> [attrs]
# Sends a span for one Task's own already-finished work, nested under an explicit
# <parent-span-id> (typically the current stage's span id). Distinct from
# otel_span_send on purpose: that function is hardcoded for a STAGE's own span (always
# parents to the flow root, and reuses its <span-id> arg AS the new span's own id,
# since that id was pre-minted by otel_stage_span_begin specifically for the stage).
# Calling otel_span_send from a Task with the stage span id doesn't nest the Task under
# the stage - it mints a span with the *same id as the stage span itself*, parented to
# the flow root as a sibling, not a child. Real bug, found live: multiple Task spans
# (and the stage span) all claiming the same (trace-id, span-id) pair meant Tempo could
# only keep one of them - explains why some Task spans silently never appeared while
# others "worked" (one arbitrary survivor of the collision). This function mints a
# genuinely fresh span id every call and takes the parent explicitly, so nesting is
# correct and no id is ever reused across spans.
otel_task_span_send() {
  : "${OTEL_EXPORTER_OTLP_ENDPOINT:?OTEL_EXPORTER_OTLP_ENDPOINT must be set (in-cluster OTel Collector)}"
  local name="$1" flow_traceparent="$2" parent_span_id="$3" start_time="$4" end_time="$5" tekton_status="$6"
  local attrs="${7:-}"
  local trace_id span_id
  trace_id="$(otel_traceparent_trace_id "${flow_traceparent}")"
  span_id="$(openssl rand -hex 8)"
  local status_code="ok"
  [[ "${tekton_status}" != "Succeeded" && "${tekton_status}" != "Completed" ]] && status_code="error"
  local -a args=(
    span --service "platform-cicd" --name "${name}"
    --force-trace-id "${trace_id}" --force-span-id "${span_id}"
    --force-parent-span-id "${parent_span_id}"
    --start "${start_time}" --end "${end_time}"
    --status-code "${status_code}"
  )
  [[ -n "${attrs}" ]] && args+=(--attrs "${attrs}")
  _otel_cli_send "${args[@]}"
}

# otel_child_span <name> <flow-traceparent> <parent-span-id> <attrs> -- <command...>
# Runs <command...> wrapped in one stateless child span via `otel-cli exec` - safe to
# call from a Task with no connection to whatever process/Pod owns the parent span,
# since parenting is set with explicit --force-*-id flags, not inherited daemon/
# process state. Used by governance-gate-stub to attach a real, queryable child span
# under the current stage span. governance.stub=true is a span *attribute* here, not
# an OTel span event - an earlier version emitted it as an event on the (unreachable)
# background span, which meant it was neither delivered nor queryable via TraceQL's
# `name =` (which matches spans, not events). A real span is straightforwardly
# queryable, e.g. `{ name =~ "^governance:.*" }`.
otel_child_span() {
  : "${OTEL_EXPORTER_OTLP_ENDPOINT:?OTEL_EXPORTER_OTLP_ENDPOINT must be set (in-cluster OTel Collector)}"
  local name="$1" flow_traceparent="$2" parent_span_id="$3" attrs="$4"; shift 4
  local trace_id
  trace_id="$(otel_traceparent_trace_id "${flow_traceparent}")"
  otel-cli exec \
    --name "${name}" \
    --service "platform-cicd" \
    --force-trace-id "${trace_id}" \
    --force-parent-span-id "${parent_span_id}" \
    --attrs "${attrs}" \
    "$@"
}
