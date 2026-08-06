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
   W3C `traceparent` (root span, no incoming parent), a real start timestamp, and a
   fresh CDEvents `chainId` - but does **not** send the flow-root span anywhere yet
   (see "otel-cli" below for why). All three are threaded through every subsequent
   Task's params within `build` via Tekton Task results.
2. `build`'s `finally` block calls `send-cdevent`, which puts the **flow-root**
   traceparent and start-time (not `build`'s own stage-span values) into the CDEvent's
   `customData.platform.traceparent` / `customData.platform.flow_start_time` fields,
   kept deliberately separate from CDEvents' own `chainId` field - one is OTel
   trace-context, the other is CDEvents' own causal-sequence correlator, and
   conflating them would make either harder to reason about or swap out independently
   later.
3. The shared broker's Trigger for this tenant extracts all three fields via a
   `TriggerBinding` and passes them as params (`flow-traceparent`, `chain-id`,
   `flow-start-time`) into the next stage's `PipelineRun` (see
   [../charts/platform-cicd-tenant/templates/triggers/ (+ templates/identity/pipeline-runner.yaml)](../charts/platform-cicd-tenant/templates/triggers/ (+ templates/identity/pipeline-runner.yaml))).
4. `test` (and later `deploy`/`release`) receive `flow-traceparent` as a Pipeline param
   instead of generating their own - they call `start-stage-span` with it, producing a
   span parented to the *original* flow root, reconstructing one continuous trace across
   PipelineRuns Tekton itself has no idea are related. `flow-start-time` keeps riding
   along, unused until whichever stage is last (`deploy`, in Phase 1) finally sends the
   flow-root span - see `end-flow-root-span.yaml`.

## otel-cli, and why spans are "begin" then "send", never "background"

Span emission from bash step scripts goes through `catalog/lib/otel.sh`, which wraps
[otel-cli](https://github.com/equinix-labs/otel-cli) (a static Go binary purpose-built
for instrumenting shell scripts - no daemon, no SDK, no non-bash runtime needed).

An earlier version of this file used otel-cli's `span background` + `span end`/`span
event` workflow: start a span in one Task, keep a local daemon alive listening on a
Unix socket, and have a *later* Task call back into that socket to close it or attach
an event. This is exactly the shape flow-root/stage spans need (start in one Task,
end in a much later one - possibly a different PipelineRun entirely) - but it was
**verified live, against real cluster data, to never work**: every span sent this way
showed an exact 1.00s duration and a `timeout` event, because each Tekton Task runs in
its own Pod, so the "end" call's socket path always pointed at an already-terminated
Pod's filesystem. otel-cli's own default `--timeout` (1s) fired every time.

The fix, in place now: **mint identifiers and a start timestamp locally (no otel-cli
call, no network), thread them through Tekton results/CDEvents exactly like
traceparent always was, and send the complete span in one stateless `otel-cli span`
call** (explicit `--start`/`--end`/`--force-trace-id`/`--force-span-id`/
`--force-parent-span-id`) only once the real end time is known - safe from any Task or
Pod, since nothing is recovered from local process state. See the file header of
`catalog/lib/otel.sh` for the exact functions (`otel_flow_root_begin`,
`otel_stage_span_begin`, `otel_span_send`, `otel_child_span`) and
`charts/platform-cicd-catalog/templates/tasks/end-flow-root-span.yaml` for why the flow-root span is currently sent
from `deploy`'s `finally` block (Phase 1's last stage) rather than from `build`.

It's fine, by design, for coarse per-step/per-stage spans (seconds to minutes - what
this platform actually needs). `otel-cli exec` (used by `otel_child_span`, e.g. for
governance-stub spans) is not the right tool for sub-second in-step instrumentation
(process-per-invocation overhead dominates at that granularity) -
`resolve-build-config`-style config-parsing steps deliberately skip span wrapping for
exactly this reason, see the comment in `charts/platform-cicd-catalog/templates/tasks/build-image.yaml`.

## Task-level spans, and a real non-toolbox-image bug found live

Phase 3 item 8.2 added task-level spans (nested under the current stage span) to the
build pipeline's variable-duration tasks: `unit-test`, `build-source`, `build-image`,
and - once real, items 8.4/8.5/8.7 - `sast-scan`, `image-scan`, `generate-sbom`.
Deliberately NOT instrumented: `validate-config`, `start-flow`, `start`/`end-*-stage-
span`, `pipelinerun-started`/`finished`, `extract-governance-flags`, `notify`,
`send-cdevent` - all low-single-digit-second tasks where otel-cli's own per-invocation
overhead isn't worth it, and `clone-repo` (a third-party hub-resolved catalog Task with
no step of ours to instrument).

Tasks that do real work inside a non-toolbox image (the resolved `build.agent` image for
`build-source`/`unit-test`, or `sast-scan`'s own `semgrep/semgrep` step) can't call
`otel_child_span` directly - neither otel-cli nor `$PLATFORM_LIB` exist there. The
pattern: stamp start/end timestamps as plain `date` output inside that step, hand them
off as Task-level results, then send the real span later from a toolbox step that does
have otel-cli.

**Real bug, found live via the user noticing missing spans in Grafana (not caught by
design/code review)**: `sast-scan.yaml`'s `scan` step used the same `date -u +"%Y-%m-
%dT%H:%M:%S.%NZ"` (nanosecond precision) pattern `build-source.yaml`/`run-tests.yaml`
already use successfully - but `semgrep/semgrep` is Alpine *without* GNU coreutils
(every build-agent image in `build-agents.env` is deliberately full/Debian-based instead,
specifically because Alpine lacks bash - a constraint that happens to also mean they all
ship real GNU `date`). Alpine's default `date` is BusyBox's, which doesn't support `%N`
and - confirmed live, not assumed - silently truncates the *entire rest* of the format
string the moment it hits `%N`, rather than erroring or printing it literally:
`date -u +"%Y-%m-%dT%H:%M:%S.%NZ"` produced `"2026-08-05T18:57:11."` - missing the
fractional seconds *and* the trailing `Z`. That malformed timestamp reached otel-cli's
`--start`/`--end` flags with no visible error, and the span simply never appeared in
Tempo. Fixed by dropping to whole-second precision (`%Y-%m-%dT%H:%M:%SZ`, no `%N`) for
this one Task - a real Semgrep scan takes seconds, so second-level precision loses
nothing meaningful. `image-scan.yaml`/`generate-sbom.yaml` were never exposed to this:
both run entirely inside the toolbox image and call `otel_child_span` directly around
the live command, no cross-image timestamp handoff at all.

Verified live afterward: a real build with `sast`/`imageScan`/`sbom` all enabled showed
all six task spans (including `image-scan`, which failed on real pre-existing CVEs -
confirming spans emit on failure too, not just success) correctly nested under
`stage:build` in a real Tempo trace.

## A real bug: sourcing otel.sh silently forces `set -e` onto the caller

`catalog/lib/otel.sh` declares `set -euo pipefail` at module level. Since `source`/`.`
runs in the *same* shell as the caller (not a subshell), this silently applies to
whatever script sourced it too - even if that script deliberately started with `set -uo
pipefail` (no `-e`) specifically because it needs to survive a command's real failure and
keep running (to build a findings summary, write an `outcome: failed` result, etc.).
Re-declaring `set -uo pipefail` again *after* the `source` line does **not** undo this -
`-u`/`pipefail` are independent toggles from `-e`, so a bare `set -uo pipefail` never
clears an already-set `-e`. Only an explicit `set +e` does.

Found live via a throwaway debug pod reproducing the exact pattern (`source otel.sh`,
then a deliberately-failing piped command, then more script) after `image-scan.yaml`'s
new post-scan findings-enrichment code silently never ran on a real scan failure - the
step's container just died right after the `trivy` call, with no error surfaced. A
full sweep of every file that sources `otel.sh` found exactly two genuinely at risk (the
only two that explicitly wanted `-e` off *and* have code after the source line that needs
to survive a failure): `image-scan.yaml` and `generate-sbom.yaml` (the latter never
actually hit this live, but has the identical structural bug waiting for the first real
`cosign attest` failure). Both now do `set +e` immediately after sourcing. Every other
otel.sh-sourcing file already declared `set -euo pipefail` itself before the source line,
so the redundant `-e` from otel.sh changes nothing for them.

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
