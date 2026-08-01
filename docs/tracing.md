# Tracing design

Goal: every build->test->deploy->release flow shows up in Grafana Tempo as **one
trace**, drillable down to individual step durations, even though each stage runs as an
independently-triggered PipelineRun with no Tekton-native relationship to the others.

## Shape: flat, not nested

The flow-root span (started once, by `build`, via `otel-flow-root-start`) is the trace's
only "top" span. Every stage's span (`start-stage-span`) parents **directly to the flow
root**, never to the previous stage's span:

```
flow-root: myapp/build-release
├── stage:build       (09:00:00 - 09:03:12)
├── stage:test         (09:03:14 - 09:05:01)
├── stage:deploy        (09:05:03 - 09:06:40)
└── stage:release        (09:06:42 - 09:12:00)
```

Nesting `test` under `build` would be wrong: `build`'s span has already closed by the
time `test` starts (they don't overlap), and Tempo's waterfall view interprets nesting
as "this ran during my parent" - nesting sequential, non-overlapping work misrepresents
duration. Flat siblings under one root is both more honest and still gives exactly the
per-stage drill-down the dashboard needs (see
[../observability/grafana/dashboards/pipeline-detail.json](../observability/grafana/dashboards/pipeline-detail.json)).

## How context crosses independently-triggered PipelineRuns

1. `build`'s first stage-relevant Task calls `start-flow-root-span`, which mints a fresh
   W3C `traceparent` (root span, no incoming parent) and a fresh CDEvents `chainId`.
   Both are threaded through every subsequent Task's params within `build` via Tekton
   Task results.
2. `build`'s `finally` block calls `send-cdevent`, which puts the **flow-root**
   traceparent (not `build`'s own stage-span traceparent) into the CDEvent's
   `customData.platform.traceparent` field, kept deliberately separate from CDEvents'
   own `chainId` field - one is OTel trace-context, the other is CDEvents' own causal-
   sequence correlator, and conflating them would make either harder to reason about or
   swap out independently later.
3. The shared broker's Trigger for this tenant extracts both fields via a
   `TriggerBinding` and passes them as params (`flow-traceparent`, `chain-id`) into the
   next stage's `PipelineRun` (see
   [../platform/broker/manifests/tenant-triggers-template.yaml](../platform/broker/manifests/tenant-triggers-template.yaml)).
4. `test` (and later `deploy`/`release`) receive `flow-traceparent` as a Pipeline param
   instead of generating their own - they call `start-stage-span` with it, producing a
   span parented to the *original* flow root, reconstructing one continuous trace across
   PipelineRuns Tekton itself has no idea are related.

## otel-cli

Span emission from bash step scripts goes through `catalog/lib/otel.sh`, which wraps
[otel-cli](https://github.com/equinix-labs/otel-cli) (a static Go binary purpose-built
for instrumenting shell scripts - no daemon, no SDK, no non-bash runtime needed). Two
things worth knowing before extending it:

- It's fine, by design, for coarse per-step/per-stage spans (seconds to minutes - what
  this platform actually needs). It is **not** the right tool for sub-second in-step
  instrumentation (process-per-invocation overhead dominates at that granularity) -
  `resolve-build-config`-style config-parsing steps deliberately skip span wrapping for
  exactly this reason, see the comment in `catalog/tasks/build-image.yaml`.
- The exact flag names in `catalog/lib/otel.sh` (`--tp-print`, `--tp-parent`, `--sockdir`,
  etc.) match otel-cli's documented "span background" workflow as of when this was
  written, but were **not independently re-verified against a pinned version** - do that
  in Phase 0 before trusting this in a real cluster (see the plan's Phase 0 checklist
  item "prove root-span + traceparent threading within a single PipelineRun first").

## Reliability gap, not yet closed

CDEvents delivery to the broker is at-least-once (plain HTTP POST with retries - see
`cdevent_send` in `catalog/lib/cdevents.sh`). Two failure modes this design doesn't yet
handle:

- **Duplicate delivery** is handled: PipelineRun names are deterministic (derived from
  the CDEvent's own `id`, itself derived from `<emitting-run-name>:<event-type>` -
  redelivery hits `AlreadyExists`, not a second run.
- **Dropped delivery** is *not* handled: if a CDEvent never arrives, the next stage
  simply never starts, and the trace silently truncates with no other signal that
  anything went wrong. A stalled-flow detector (expected-next-stage-didn't-start-within-
  N-minutes alert, surfaced in the dashboard) is a named Phase 2 follow-up, not yet
  built - see the plan's Phase 2 item.
