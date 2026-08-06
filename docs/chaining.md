# Inter-stage chaining

`build -> test -> deploy -> release` is four independent Tekton `Pipeline`s, run as four
independent `PipelineRun`s, with **no direct Tekton relationship between them** (no
`runAfter` across Pipelines, no Pipelines-in-Pipelines nesting). This is deliberate, not
a limitation: keeping stages decoupled means any one of them can be re-triggered alone,
gated independently, or observed in isolation, which tight coupling would prevent. See
the plan's Q1 review notes for why "Pipelines-in-Pipelines" was explicitly considered and
rejected.

## Why not Pipelines-as-Code for this

PaC triggers on **git events** (push/PR/tag/comment) via its GitHub App. "Stage N just
finished" is not a git event - it's an internal fact the platform itself produces - so
PaC has no mechanism for it and isn't supposed to. This is why the platform has two
distinct triggering mechanisms rather than trying to force one tool to do both jobs; see
the top-level [README.md](../README.md) architecture summary.

## The shared broker

One Tekton Triggers `EventListener` (`charts/platform-cicd-control-plane/templates/broker/eventlistener.yaml`,
2-3 replicas, stateless), shared across every Application - **not** one EventListener per
Application. An earlier draft of this design had per-app EventListener pods; design
review rejected that as an unnecessary ongoing operational tax (patch/cert/config drift
multiplied by app count) that bought no real isolation the shared-broker-plus-RBAC
approach doesn't already provide.

**Authentication**: each pipeline pod's own cluster-issued, audience-bound projected
ServiceAccount token (`audience: cdevents-broker`, minted fresh per Task run, 10-minute
expiry - see the `volumes:` block in `charts/platform-cicd-catalog/templates/tasks/send-cdevent.yaml`), verified by a
small custom `ClusterInterceptor`
(`platform/broker/cmd/token-review-interceptor`) calling the Kubernetes `TokenReview`
API. There is no platform-minted credential anywhere in this path - this is what
replaces the old platform's JWT-minting server, its rotation CronJob, and the GitHub-
secret-publishing step entirely.

**App isolation**: the interceptor sets `extensions.app_namespace` to the calling
SA's own namespace (verified by Kubernetes itself, not asserted by the caller). Every
Application's own `Trigger` CEL filter checks that against the CDEvent's declared
`context.source` namespace before matching - this, not NetworkPolicy, is the real trust
boundary on a broker every Application's traffic passes through. NetworkPolicy
(default-deny + allow-from-same-namespace) is defense-in-depth on top of it, not a
substitute for it - and only works at all if the cluster's CNI actually enforces
NetworkPolicy (see [bootstrap.md](bootstrap.md) on why Calico is a hard prerequisite,
not a nice-to-have, in `hack/kind-config.yaml`).

**PipelineRun creation identity**: when a `Trigger` fires, Tekton Triggers creates the
resulting `PipelineRun` using *that Trigger's own* `spec.serviceAccountName` - each
Application's own least-privilege, namespace-scoped `pipeline-runner` SA (see
`charts/platform-cicd-app/templates/triggers/` (+ `templates/identity/pipeline-runner.yaml`)), never the broker's own
identity. The broker's ServiceAccount holds no rights to create PipelineRuns anywhere;
it can only watch `Trigger`/`TriggerBinding`/`TriggerTemplate` objects cluster-wide.

The hand-off from "broker validated the caller" to "the Application's own SA creates the
PipelineRun" is implemented via **scoped Kubernetes impersonation**: each Application's
onboarding grants the broker's SA `impersonate` on exactly that Application's one named
`pipeline-runner` SA, in that one namespace only (a namespaced `Role`+`RoleBinding`
living in the Application's own namespace - see the "Scoped impersonation grant" block in
`charts/platform-cicd-app/templates/identity/pipeline-runner.yaml`). Compare this to the
old platform's single cluster-wide `impersonate` on *every* ServiceAccount plus an
unrelated `cluster-admin` `ClusterRoleBinding` bound to the same identity: this is the
same underlying Kubernetes mechanism, narrowed to one explicit, auditable,
individually-revocable grant per Application, with no cluster-admin anywhere in the
picture.

**Verify in Phase 0**: the exact mechanism Tekton Triggers uses to hand off to a
Trigger's named ServiceAccount (impersonation vs. some other token-based approach) is
documented above based on how Tekton Triggers has historically implemented
`serviceAccountName`, but was not independently re-verified against a specific pinned
release while writing this. Confirm it before treating
`charts/platform-cicd-app/templates/identity/pipeline-runner.yaml`'s RBAC block as
correct in a real cluster - if the mechanism differs, this file (and this doc) is the
one place that needs to change, not any Task or Pipeline.

## Why an Application is (at least) two namespaces, not one

Every namespace an Application gets follows the same flat `<type>-<app-name>-<env>`
pattern (see docs/concepts.md) - `<type>-<app-name>-cicd` (e.g. `app-platform-cicd-demo-
cicd`) and `<type>-<app-name>-<env>` (e.g. `app-platform-cicd-demo-dev`) are deliberately
separate, PEER namespaces with different jobs, not a base-plus-suffix pair:

- `<type>-<app-name>-cicd` is the Application's *CI control plane* - where
  `pipeline-runner` and its RBAC live, where PaC actually creates build/test
  PipelineRuns (that's where the `Repository` CR and the chaining `Trigger` CRs from
  `charts/platform-cicd-app/templates/triggers/*.yaml` live), where kaniko's registry
  push credentials sit. Pipelines *execute* here.
- `<type>-<app-name>-<env>` is where the *deployed application* actually runs - the
  long-lived `Deployment`/`Service` serving traffic. `deploy-manifests.yaml` derives
  this name directly from `app-type`/`app-name`/`env` params (never by suffixing the
  cicd namespace) specifically so each environment (`dev`, and later `staging`/`prod`
  per `cicd.yaml`'s `deploy.upperEnvironments`) gets its own isolated namespace, rather
  than every environment's Deployment colliding in one namespace.

The split matters for RBAC, not just tidiness: `pipeline-runner`'s Role in
`charts/platform-cicd-app/templates/identity/pipeline-runner.yaml` only grants rights
inside the Application's own `<type>-<app-name>-cicd` namespace - a namespace-scoped
`Role` never extends into a different namespace. Deploying into `<type>-<app-name>-<env>`
needs its own, separate grant - see
`charts/platform-cicd-app/templates/env/deploy-rbac.yaml`, applied once per environment
(a real gap caught the same way most of this doc's caveats were: by reasoning through
what actually calls what, not by running it and hoping).

## What flows through the broker (Phase 1)

- `dev.cdevents.artifact.published.0.3.0` (from `build`) -> fires `test`
- `dev.cdevents.testcaserun.finished.0.3.0`, `outcome=Succeeded` (from `test`) -> fires
  `deploy`

`deploy -> release` chaining, and `release`'s own event, are Phase 2 (see the plan).

## Deeper CDEvents coverage (Phase 3 item 1)

Every stage's domain-specific event above (`artifact.published`, `testcaserun.finished`,
`service.deployed`, `change.created`) is what actually drives chaining, and that hasn't
changed. Separately, every pipeline now also emits a **generic, uniform** pair of events
that no future subscriber needs to already know each stage's specific vocabulary to use:
`dev.cdevents.pipelinerun.started.0.3.0` and `dev.cdevents.pipelinerun.finished.0.3.0`.
This is a deliberate architectural stance - CDEvents as a platform-wide "event driven"
principle, not just a chaining transport - with no concrete subscriber yet; it's building
the event surface ahead of the consumer, not the other way around.

Verified against the real CDEvents spec (`cdevents/spec` on GitHub) before building
against it: `pipelineRun` and `taskRun` are both **core** CDEvents subject types (distinct
from the Continuous Integration vocabulary's `build`/`artifact` subjects this platform
already used), each with three predicates - `queued`, `started`, `finished`.
`subject.content` for `pipelineRun`: optional `pipelineName`/`url`; `finished` adds
`outcome` (enum `success`/`failure`/`cancel`/`error`) and optional `errors`.

**Scoping decisions, made deliberately, not silently omitted:**

- **Pipeline-level only (`pipelinerun.*`), not task-level (`taskrun.*`).** Task-level
  would mean instrumenting every catalog Task individually - a much larger, separately-
  scoped effort with a different risk profile.
- **`started`/`finished` only, not `queued`.** `queued` is architecturally awkward in
  Tekton's model: it's meant to represent the moment *before* a PipelineRun starts
  running, but the only thing capable of making the broker call is a Tekton Task, which
  cannot execute until its own PipelineRun already exists and is running - it literally
  cannot observe the state that precedes its own execution. A real `queued` event would
  need a different actor entirely (something watching PipelineRun *creation* from
  outside), which is separable infrastructure, not a natural extension of the existing
  `send-cdevent` pattern every other event here uses.
- **No changes to the existing domain events or the broker's chaining Triggers.** Every
  Trigger's CEL filter (`charts/platform-cicd-app/templates/triggers/*.yaml`) checks
  an exact `body.context.type` string - a new type the filter doesn't check for simply
  never matches, so this is safely additive to the real chaining mechanism.

**Placement**: `pipelinerun.started` fires with no `runAfter` dependency (parallel with
`clone-repo`) in `test`/`deploy`/`release`, since `chain-id`/`traceparent`/
`flow-start-time` already arrive as incoming Pipeline params for those three. In `build`
it fires `runAfter: [start-flow]` instead, alongside `start-build-stage-span` - build is
the flow *root*, so those values don't exist until `start-flow` generates them. This
means build's `pipelinerun.started` fires a few tasks later than the other three stages' -
a real, accepted asymmetry, not an oversight.

`pipelinerun.finished` lives in every pipeline's `finally:` block, alongside (not
replacing) the existing domain-specific event - **deliberately not gated** on
`tasks.status in [Succeeded, Completed]` the way the domain events mostly are, because
"the pipeline finished" is true whether it succeeded or failed, and a uniform completion
signal that only reports on success isn't a useful uniform signal at all.

**Outcome mapping**: Tekton's real `status.conditions[].reason` values (`Succeeded`,
`Completed`, `Failed`, `Cancelled`, `PipelineRunTimeout`, plus other less common error
reasons - confirmed against Tekton's own docs) don't match CDEvents' `outcome` enum
(`success`/`failure`/`cancel`/`error`) directly. Rather than hand-mapping this in every
pipeline's YAML (Tekton param wiring has no conditional logic - only a Task's own script
can compute a mapped value), `charts/platform-cicd-catalog/templates/tasks/send-cdevent.yaml` gained one new **optional**
param, `tekton-status` (default `""`). When set (every `pipelinerun-finished` task passes
`$(tasks.status)`), the script maps it via `cdevents_map_outcome()` (new in
`catalog/lib/cdevents.sh`, a small pure function alongside `cdevent_send()`, not replacing
it) and merges `{"outcome": "<mapped>"}` into `subject-content-json` via `jq` before
sending. Existing call sites that don't pass `tekton-status` are completely unaffected -
the param defaults empty and no merge happens - so this is backward-compatible by
construction.

`errors` (the optional finished-predicate failure-detail field) is left unpopulated for
now - meaningfully populating it means fetching a failed TaskRun's log output, which
overlaps with the Phase 3 Slack-notifications item's own "failure log excerpts" goal;
better built once, shared, when that item is tackled, not duplicated here.

### Fixed: every event's `subject.type` was hardcoded wrong

Building the events above surfaced a real, pre-existing bug: `cdevent_send()` hardcoded
`subject.type: "pipelinerun"` for *every* event it ever sent, including
`artifact.published`, `testcaserun.finished`, and `service.deployed`/`change.created` -
none of which have a pipelineRun subject at all per the real CDEvents spec. Fixed by
making `subject-type` a required (no default) argument to `cdevent_send()` and a required
param on `send-cdevent.yaml`, with every one of the 12 call sites across
`build`/`test`/`deploy`/`release.yaml` passing the correct value explicitly:
`artifact` (`artifact.published`), `testCaseRun` (`testcaserun.finished`), `service`
(`service.deployed`), `change` (`change.created`), `pipelineRun` (both new
`pipelinerun.started`/`.finished` events). No default value was given deliberately - a
silently-wrong default would just reproduce this same bug for the next new call site.
Casing matches the CDEvents spec's own subject-name convention (camelCase for multi-word
subjects, confirmed against a real spec example showing `content.pipelineRun`; lowercase
for single-word ones). Doesn't affect chaining or the deterministic-naming/dedup scheme -
both key off `event_type`/PipelineRun name, never `subject.type` - verified via a real
end-to-end chain after the fix, not just reasoned about.
