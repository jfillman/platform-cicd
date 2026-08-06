# Stalled-pipeline detector

Detects a stage that completed successfully but whose expected next-stage PipelineRun
never appeared - meaning a CDEvent got lost somewhere between that stage's `finally`
block and the broker's Trigger actually firing. This session hit exactly this failure
class repeatedly and manually (the recurring cloudflared tunnel dying with nothing
downstream to notice a PR sat unbuilt) - this closes that gap with an automated check.

## What this is not

The architecture plan originally bundled this with "CDEvents idempotency/dedup." Live
code inspection found the dedup half was already built during Phase 1:
`charts/platform-cicd-app/templates/triggers/*.yaml` names every triggered
PipelineRun deterministically (`test-$(body.context.id)`, etc.), and that `id` is itself
`sha256(emitting-PipelineRun-name:event-type)[:20]`, computed in
`catalog/lib/cdevents.sh`'s `cdevent_send()`. At-least-once redelivery of the same
CDEvent therefore either creates the PipelineRun once or hits a harmless
`AlreadyExists`. This detector covers the opposite failure: a stage finishing and
**nothing** happening next.

## Detection mechanism

No new labels or state needed. Since a completed stage's PipelineRun name is known, and
the next stage's expected name is `sha256("<this-run-name>:<event-type>")[:20]` prefixed
with the next stage's name - the exact computation `cdevent_send()` already does - the
detector recomputes that value directly and checks whether a PipelineRun with that name
exists:

| Completed stage | Event type | Expected successor |
|---|---|---|
| `build-*` | `dev.cdevents.artifact.published.0.3.0` | `test-<hash>` |
| `test-*` | `dev.cdevents.testcaserun.finished.0.3.0` | `deploy-<hash>` |
| `deploy-*` | `dev.cdevents.service.deployed.0.3.0` | `release-<hash>` |
| `release-*` | (none - terminal) | n/a |

A successor is only ever expected when the completed PipelineRun's own Tekton condition
is `status: "True"`, reason `Succeeded`/`Completed` - matching exactly what already gates
`send-cdevent` in `build.yaml`/`deploy.yaml` and what `test.yaml`'s Trigger CEL filter
checks. A **failed** stage is a different, already-visible condition (shows up directly
as a Failed PipelineRun, and `notify-slack` already fires on it) - not a silent stall, so
it's deliberately excluded.

The hash computation is duplicated in the CronJob's script rather than sourced from
`cdevents.sh` directly, since that script hard-requires several env vars
(`CDEVENTS_BROKER_URL`, etc.) this CronJob has no reason to set. If the algorithm in
`cdevents.sh` ever changes, `stalled-pipeline-detector-cronjob.yaml` needs to change with
it - flagged explicitly in both files' comments.

## Scan scope, threshold, and dedup

Scans **cluster-wide** (`pipelineruns.tekton.dev` across every namespace) rather than
discovering Application namespaces via a label, because no such label convention exists
anywhere in this platform yet - the broker's own `EventListener` already takes the same
`namespaceSelector: {matchNames: ["*"]}` approach (`eventlistener.yaml`), relying on
RBAC/Trigger-CR scoping rather than a namespace allowlist. This follows that precedent.

A candidate stage must be older than `STALL_THRESHOLD_MINUTES` (default 10, by
`.status.completionTime`) before being flagged - long enough that ordinary image-pull/
scheduling latency doesn't false-positive.

Once alerted, the detector labels the *stalled* (predecessor) PipelineRun
`platform.io/stall-alerted: "true"` and skips already-labeled runs on future scans -
state lives on the object itself, no new datastore.

## Alerting - deliberately not the per-app Slack webhook

`notify-slack.yaml` reads each Application's own `slack-webhook-url` Secret, mounted into that
Application's own pipeline pods. Reusing it here would mean granting this cluster-scoped
detector `get` on Secrets across *every* Application's namespace just to fetch webhook URLs - a
real, avoidable widening of blast radius this platform has been careful about everywhere
else (TokenReview-scoped brokering, per-app impersonation, read-only Dashboard RBAC),
for a payoff that isn't worth that cost.

Instead, a genuine stall produces:
1. A plain Kubernetes `Event` (core `v1`, `involvedObject` pointing at the stalled
   PipelineRun) - visible directly via `kubectl describe pipelinerun <name>` and
   `kubectl get events -n <app-namespace>`.
2. A structured `STALL DETECTED` log line to stdout, which the platform's existing Loki
   collection already ingests - e.g. `{namespace="platform-system", pod=~"stalled-
   pipeline-detector.*"} |= "STALL DETECTED"` surfaces every stall across every Application in
   one Grafana Explore query, with no new wiring.

Piping this into an Application's Slack channel is a small, clearly separable follow-up (e.g. a
Grafana Loki alert rule) - not built now, since it would reopen the Secrets-RBAC question
above for a feature nobody's asked for yet.

## RBAC

Cluster-scoped by necessity (PipelineRuns live in every Application's namespace, same
unavoidable exception as the TTL sweep's namespace access), narrow by verb: `get`/`list`/
`patch` on `pipelineruns.tekton.dev` (patch only for the dedup label), `create` on
`events`. Nothing else - no Secrets, no other resource types, no write access to a
PipelineRun's actual spec/status.

## Verification

- Live-tested by temporarily appending `&& false` to the `on-build-success` Trigger's CEL
  filter in an Application namespace (not by scaling the shared `EventListener` to zero -
  that would make `send-cdevent`'s own `curl` fail, which by Tekton's default
  `finally`-task semantics flips the *whole* PipelineRun to `Failed`, which this detector
  correctly excludes as an already-visible condition, not a silent stall - so that
  approach wouldn't actually exercise the detector at all). This makes the broker accept
  and 200 the CDEvent while silently dropping the match - the real target failure mode.
- Confirmed a real `build` PipelineRun completes `Succeeded` with no corresponding
  `test-*` PipelineRun ever appearing.
- Manually triggered the CronJob (`kubectl create job --from=cronjob/stalled-pipeline-
  detector ...`); confirmed it detects the stall, creates the `Event`, and applies the
  dedup label.
- Re-ran immediately; confirmed the same stall does **not** re-alert.
- Restored the Trigger's original CEL filter afterward.
- False-positive check: verified the hash recomputation against several real, already-
  completed `build`->`test` pairs on the live cluster before relying on it - the detector
  raises zero alerts against a healthy chain.
- RBAC check: `kubectl auth can-i --list
  --as=system:serviceaccount:platform-system:stalled-pipeline-detector` shows exactly
  `get`/`list`/`patch` on `pipelineruns.tekton.dev` and `create` on `events`.
