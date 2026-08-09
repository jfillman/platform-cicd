# Naming conventions

Written 2026-08-06 after auditing real inconsistencies (not guessed) - see the specific
findings inline below. This is the durable reference; new catalog Tasks, Pipelines,
namespaces, and files should follow this rather than the nearest existing example, since
a few existing examples are exactly the inconsistencies this doc fixes.

## Namespaces

**One flat pattern: `<type>-<app-name>-<env>`.** `type` is `app` (a regular Application)
or `infra` (a shared/platform-adjacent service onboarded with its own pipeline - e.g. a
future shared DB operator) - more types added as real cases show up, not invented
speculatively. `env` is whichever environment that particular namespace represents -
`cicd` (the Application's own pipeline-execution namespace), `dev`, `staging`,
`pr-<number>`, or any other declared deploy target. All of these are **siblings under
the same pattern**, not a base-plus-suffix hierarchy - a deploy namespace has nothing to
do with "cicd" conceptually (it's where the Application *runs*, not where its pipeline
runs), so it is never `<type>-<app-name>-cicd-<env>`.

Examples, all structurally identical 3-part names: `app-nodejs-demo-app-cicd` (pipeline
execution), `app-nodejs-demo-app-dev` (deploy target), `app-nodejs-demo-app-staging`
(release staging), `app-nodejs-demo-app-pr-42` (PR ephemeral env),
`infra-payments-db-cicd` (an `infra`-type Application's own pipeline execution).

`charts/platform-cicd-app`'s `platform-cicd-app.envNamespace` helper computes any of
these from `platformIdentity.type` + `platformIdentity.appName` + a given `env` value -
nothing is a separately-set, independently-typed field that could drift from the
convention.

Watch the 63-character Kubernetes namespace limit (a real DNS-1123 constraint, not a
style preference) on longer app names combined with the `-pr-<number>` suffix.

**Platform-level namespaces** keep the existing `platform-*` prefix - already consistent,
not changing: `platform-system`, `platform-catalog`, `platform-catalog-canary`,
`platform-secrets`.

**Third-party namespaces** (`argocd`, `tekton-chains`, `fulcio-system`,
`external-secrets`, `observability`, `crossplane-system`) are not ours to rename - keep
whatever that tool's own install convention uses.

**Helm release name = namespace name, exactly.** `helm install <type>-<app-name>-cicd
charts/platform-cicd-app ...` - one less thing to keep in sync by hand.

## Catalog Task names

Verb-noun (or verb-only), kebab-case, matching the file name exactly
(`build-image.yaml` -> `build-image`). Already consistent across the whole catalog -
confirmed by auditing all 26 Task names live before writing this doc. Keep it that way.

## Catalog Pipeline names

Noun matching the stage or check it represents: `build`, `test`, `deploy`, `release`,
`sast-check`, `image-scan-check`, `policy-check`, `sbom-check`, `governance-check`,
`bypass-merge-check`, `onboarding-resync`. Already consistent.

## Step names within a Task - the real inconsistency, now fixed

Audited live: three genuinely different patterns existed under one implied name,
`emit-span`/span-related steps:

1. **Dedicated step, sole job is sending a pre-computed span** (`otel_task_span_send`):
   `build-source.yaml`, `run-tests.yaml`, `sast-scan.yaml` - each has a step named
   exactly `emit-span`. **This is the standard - use this shape whenever a Task can
   afford a dedicated trailing step.**
2. **The same `otel_task_span_send` call, folded into a step doing something else**:
   `build-image.yaml`'s `emit-image-ref-result` step also sends the Task's span, for a
   real structural reason (kaniko has no shell, so the span has to be sent from
   whichever bash step runs after it, and that step already exists to extract kaniko's
   results) - but the step's name didn't disclose the second job. **Fixed**: renamed to
   `emit-image-ref-and-span`. When a span-send has to be folded into another step for a
   similar structural reason, name the step to disclose both jobs - never let a name
   describe only one of two things a step does.
3. **No separate step at all - `otel_child_span` wraps the live command directly**:
   `image-scan.yaml`, `generate-sbom.yaml`. This is a genuinely different, correct
   mechanism (you can't retroactively wrap a step that already finished with a span
   covering its execution), not a naming gap - document it as an intentional exception
   where it appears, don't leave it looking like an oversight.

`start-span`/`end-span` (used by `start-stage-span.yaml`/`end-stage-span.yaml`/
`start-flow-root-span.yaml`/`end-flow-root-span.yaml`) are intentionally a different
name from `emit-span` - they're a genuine two-phase begin/end pair spanning *separate*
Tekton Tasks (sometimes separate PipelineRuns entirely), not a one-shot send within a
single Task. Don't unify these names - the distinction is real and worth keeping
visible.

Other step-name patterns already consistent, keep using them: `resolve-*` for
config/parameter-resolution steps that run before the real work (`resolve-build-config`,
`resolve-test-command`, `resolve-build-script-path`), and a plain verb (or
verb-noun) for the step doing the actual work (`scan`, `build-and-push`,
`run-build-script`, `unit-test`, `generate-and-attest`).

## PipelineRun naming

**`generateName` must always end in `-`.** This is the actual root cause of PipelineRun
names like `sastgdn8r` instead of `sast-gdn8r` - confirmed live: the five gitops-repo
governance-check trigger files (`sast`, `policy-check`, `image-scan`, `sbom`,
`bypass-check`) were missing the trailing dash, while the app-repo side (`build-`,
`pr-validate-`, `onboarding-resync-`) already had it right. **Fixed** - all eight
`generateName` values in `charts/platform-cicd-app/files/onboarding-templates/` now end in `-`.

**Confirmed live, and this is a genuine, unavoidable trade-off, not an oversight**:
Pipelines-as-Code derives the GitHub Check context name directly from
`metadata.generateName`, verbatim - no trailing-dash trimming (confirmed via a real test
PR against `gitops-nodejs-demo-app`: adding the dash produced a real PipelineRun name
like `sast-gdn8r`, but the check name became `sast-` too, not `sast`). No annotation to
decouple the two was found after a real search of PaC's docs. Since the clean check name
(`sast`, not `sast-`) is the explicitly stronger preference, the five gitops-repo
governance-check files **keep their dash-free `generateName`** - the resulting
`sastgdn8r`-style PipelineRun name is the accepted cost of the cleaner, more visible
check name. Don't "fix" this again without a real mechanism to set the check name
independently of `generateName` - reverting this exact change was itself the fix.

Deterministic (non-`generateName`) PipelineRun names fired by the broker
(`test-$(body.context.id)`, `deploy-...`, `release-...`) already use a real separator -
no change needed, already the correct pattern to match.

## GitHub Check / status context names

Short, no trailing dash, matching the concept the file represents (`sast`,
`policy-check`, `image-scan`, `sbom`, `bypass-check`). Confirmed-good, keep as-is.

## Helm chart and file naming

- Chart names: `platform-cicd-<concern>` (`platform-cicd-catalog`,
  `platform-cicd-control-plane`, `platform-cicd-app`).
- Catalog Task/Pipeline/StepAction files: `<metadata.name>.yaml`, exactly - already the
  norm, keep it exact (a mismatch is a real "which file is this Task actually defined
  in" trap).
- Chart template subdirectories grouped by concern, not resource kind:
  `identity/`, `triggers/`, `env/`, `argocd/`, `governance/`, `sigstore/`, `broker/`,
  `dora-exporter/`, `hooks/`, `secretstore/`.
- Docs: kebab-case, descriptive noun-phrase (`catalog-versioning.md`,
  `secrets-management.md`) - already consistent.

## Labels and annotations

`platform.io/*` is this platform's own label namespace. As of this pass, every resource
across all three charts (116 total: 43 catalog, 38 control-plane, 35 in a full-fixture
App render) carries a full, consistent label set via a per-chart `<chart>.labels`
named template (`templates/_helpers.tpl`) - not just the handful of resources that
happened to need a label for a real selector before now.

**Standard Kubernetes-recommended labels** (`app.kubernetes.io/*` + `helm.sh/chart`) -
generic tooling interop (kubectl, Lens, ArgoCD's own resource tree), not platform-
specific:

```yaml
app.kubernetes.io/name: <chart name>
app.kubernetes.io/instance: <helm release name>
app.kubernetes.io/version: <Chart.yaml appVersion>
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: platform-cicd
helm.sh/chart: <chart name>-<chart version>
```

**`platform.io/component`**: `catalog` | `control-plane` | `app` - which of the three
charts owns this resource. The single most useful selector for a cross-cutting audit,
e.g. `kubectl get role -A -l platform.io/component=app`.

**`platform.io/subcomponent`**: which concern *within* that chart - matches the template
subdirectory a resource's file lives in (`identity`, `triggers`, `env`, `argocd`,
`governance`, `broker`, `dora-exporter`, `sigstore`, `hooks`, `secretstore`). Lets you
narrow `platform.io/component=control-plane` down to just
`platform.io/subcomponent=sigstore`, for example.

**`platform.io/app`** (app chart only, on every resource it creates): most valuable on
the resources that live in a *shared* namespace with other Applications' resources
(`argocd`'s AppProjects/Applications/ApplicationSets/Roles) - lets you
`kubectl get application -n argocd -l platform.io/app=nodejs-demo-app` instead of relying
on name-pattern matching. Applied to every app-chart resource, not just the
shared-namespace ones, for consistency.

**`platform.io/stub`**: `"true"` on catalog resources that are still genuinely stub
implementations - currently `governance-gate-stub` (Task), `governance-stub`
(StepAction), `governance-check` (Pipeline, though live-confirmed unreferenced by any
current onboarding trigger - a real, minor dead-code finding, not acted on here).
Reinforces this platform's existing "stub-ness must be structurally loud" principle
(previously only visible in trace span attributes and docs) at the resource-selection
level too: `kubectl get task -n platform-catalog -l platform.io/stub=true` now answers
"which catalog gates are still fake" directly.

**Pre-existing `platform.io/*` labels/annotations** (kept exactly as-is, already
consistent with this scheme): `platform.io/catalog: "true"` (catalog-resolvable
resources), `platform.io/dora-track: "true"` (Applications the DORA exporter watches),
`platform.io/dora-pending`/`-app-namespace`/`-app`/`-flow-start-time`/`-baseline-started-at`
(DORA tracking state annotations on Applications), `platform.io/stall-alerted` (dedup
marker), `platform.io/ephemeral-env` (PR-namespace TTL sweep target marker),
`platform.io/purpose` (free-text annotation, currently only on the ClusterSecretStore's
source namespace).

A real bug found and fixed while applying this broadly: two pre-existing resources
(`fulcio-server`'s Deployment, `dora-exporter`'s Service) already had their own
`metadata.labels` block for an unrelated reason (a plain `app: <name>` selector label) -
naively inserting a second `labels:` key produced invalid/duplicate-key YAML rather than
merging. Fixed by merging into one block in both cases; swept the whole of `charts/` for
the same class of bug afterward (both block-style and flow-style `labels: { ... }`) and
confirmed zero remaining occurrences before considering this done.
