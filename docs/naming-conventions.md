# Naming conventions

Written 2026-08-06 after auditing real inconsistencies (not guessed) - see the specific
findings inline below. This is the durable reference; new catalog Tasks, Pipelines,
namespaces, and files should follow this rather than the nearest existing example, since
a few existing examples are exactly the inconsistencies this doc fixes.

## Namespaces

**Tenant pipeline-execution namespace**: `<type>-<app-name>-cicd`, where `type` is
`app` (a regular application tenant) or `infra` (a shared/platform-adjacent service
onboarded with its own pipeline - e.g. a future shared DB operator) - more types added
as real cases show up, not invented speculatively. Examples: `app-nodejs-demo-app-cicd`,
`infra-payments-db-cicd`. This is `platformIdentity.tenantNamespace`'s value - the tenant
chart doesn't compute or enforce this pattern, it's a convention for what you set that
value to, same as every other `platformIdentity` field.

Everything derived from the tenant namespace keeps its existing suffix pattern, just
built on the new base:

- Deploy target: `<type>-<app-name>-cicd-<env>` (e.g. `app-nodejs-demo-app-cicd-dev`)
- Release staging: `<type>-<app-name>-cicd-staging`
- PR ephemeral envs: `<type>-<app-name>-cicd-pr-<number>`

Watch the 63-character Kubernetes namespace limit (a real DNS-1123 constraint, not a
style preference) on longer app names combined with the `-pr-<number>` suffix.

**Platform-level namespaces** keep the existing `platform-*` prefix - already consistent,
not changing: `platform-system`, `platform-catalog`, `platform-catalog-canary`,
`platform-secrets`.

**Third-party namespaces** (`argocd`, `tekton-chains`, `fulcio-system`,
`external-secrets`, `observability`, `crossplane-system`) are not ours to rename - keep
whatever that tool's own install convention uses.

**Helm release name = namespace name, exactly.** `helm install <type>-<app-name>-cicd
charts/platform-cicd-tenant ...` - one less thing to keep in sync by hand.

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
`generateName` values in `onboarding-templates/.tekton*/` now end in `-`.

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
  `platform-cicd-control-plane`, `platform-cicd-tenant`).
- Catalog Task/Pipeline/StepAction files: `<metadata.name>.yaml`, exactly - already the
  norm, keep it exact (a mismatch is a real "which file is this Task actually defined
  in" trap).
- Chart template subdirectories grouped by concern, not resource kind:
  `identity/`, `triggers/`, `env/`, `argocd/`, `governance/`, `sigstore/`, `broker/`,
  `dora-exporter/`, `hooks/`, `secretstore/`.
- Docs: kebab-case, descriptive noun-phrase (`catalog-versioning.md`,
  `secrets-management.md`) - already consistent.

## Labels

`platform.io/*` is this platform's own label namespace - already established
(`platform.io/catalog`, `platform.io/dora-track`, `platform.io/stall-alerted`,
`platform.io/ephemeral-env`). Use it for anything new that needs to be selectable/
filterable, to avoid colliding with another tool's labels on a shared resource type
(e.g. ArgoCD `Application`s, where `podinfo-demo-app` and other non-platform
Applications already coexist in the same `argocd` namespace).
