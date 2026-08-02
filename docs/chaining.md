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

One Tekton Triggers `EventListener` (`platform/broker/manifests/eventlistener.yaml`,
2-3 replicas, stateless), shared across every tenant - **not** one EventListener per
tenant. An earlier draft of this design had per-tenant EventListener pods; design review
rejected that as an unnecessary ongoing operational tax (patch/cert/config drift
multiplied by tenant count) that bought no real isolation the shared-broker-plus-RBAC
approach doesn't already provide.

**Authentication**: each pipeline pod's own cluster-issued, audience-bound projected
ServiceAccount token (`audience: cdevents-broker`, minted fresh per Task run, 10-minute
expiry - see the `volumes:` block in `catalog/tasks/send-cdevent.yaml`), verified by a
small custom `ClusterInterceptor`
(`platform/broker/cmd/token-review-interceptor`) calling the Kubernetes `TokenReview`
API. There is no platform-minted credential anywhere in this path - this is what
replaces the old platform's JWT-minting server, its rotation CronJob, and the GitHub-
secret-publishing step entirely.

**Tenant isolation**: the interceptor sets `extensions.tenant_namespace` to the calling
SA's own namespace (verified by Kubernetes itself, not asserted by the caller). Every
tenant's own `Trigger` CEL filter checks that against the CDEvent's declared
`context.source` namespace before matching - this, not NetworkPolicy, is the real trust
boundary on a broker every tenant's traffic passes through. NetworkPolicy
(default-deny + allow-from-same-namespace) is defense-in-depth on top of it, not a
substitute for it - and only works at all if the cluster's CNI actually enforces
NetworkPolicy (see [bootstrap.md](bootstrap.md) on why Calico is a hard prerequisite,
not a nice-to-have, in `hack/kind-config.yaml`).

**PipelineRun creation identity**: when a `Trigger` fires, Tekton Triggers creates the
resulting `PipelineRun` using *that Trigger's own* `spec.serviceAccountName` - each
tenant's own least-privilege, namespace-scoped `pipeline-runner` SA (see
`platform/broker/manifests/tenant-triggers-template.yaml`), never the broker's own
identity. The broker's ServiceAccount holds no rights to create PipelineRuns anywhere;
it can only watch `Trigger`/`TriggerBinding`/`TriggerTemplate` objects cluster-wide.

The hand-off from "broker validated the caller" to "tenant's own SA creates the
PipelineRun" is implemented via **scoped Kubernetes impersonation**: each tenant's
onboarding grants the broker's SA `impersonate` on exactly that tenant's one named
`pipeline-runner` SA, in that one namespace only (a namespaced `Role`+`RoleBinding`
living in the tenant's own namespace - see the "Scoped impersonation grant" block in
`tenant-triggers-template.yaml`). Compare this to the old platform's single cluster-wide
`impersonate` on *every* ServiceAccount plus an unrelated `cluster-admin`
`ClusterRoleBinding` bound to the same identity: this is the same underlying Kubernetes
mechanism, narrowed to one explicit, auditable, individually-revocable grant per tenant,
with no cluster-admin anywhere in the picture.

**Verify in Phase 0**: the exact mechanism Tekton Triggers uses to hand off to a
Trigger's named ServiceAccount (impersonation vs. some other token-based approach) is
documented above based on how Tekton Triggers has historically implemented
`serviceAccountName`, but was not independently re-verified against a specific pinned
release while writing this. Confirm it before treating `tenant-triggers-template.yaml`'s
RBAC block as correct in a real cluster - if the mechanism differs, this file (and this
doc) is the one place that needs to change, not any Task or Pipeline.

## Why a tenant is two namespaces, not one

`<TENANT>` (e.g. `platform-cicd-demo`) and `<TENANT>-<ENV>` (e.g.
`platform-cicd-demo-dev`) are deliberately separate namespaces with different jobs:

- `<TENANT>` is the tenant's *CI control plane* - where `pipeline-runner` and its RBAC
  live, where PaC actually creates build/test PipelineRuns (that's where the
  `Repository` CR and the chaining `Trigger` CRs from `tenant-triggers-template.yaml`
  live), where kaniko's registry push credentials sit. Pipelines *execute* here.
- `<TENANT>-<ENV>` is where the *deployed application* actually runs - the long-lived
  `Deployment`/`Service` serving traffic. `deploy-manifests.yaml` derives this name as
  `<tenant>-<env>` specifically so each environment (`dev`, and later `staging`/`prod`
  per `cicd.yaml`'s `deploy.upperEnvironments`) gets its own isolated namespace, rather
  than every environment's Deployment colliding in one namespace.

The split matters for RBAC, not just tidiness: `pipeline-runner`'s Role in
`tenant-triggers-template.yaml` only grants rights inside `<TENANT>` - a namespace-
scoped `Role` never extends into a different namespace. Deploying into `<TENANT>-<ENV>`
needs its own, separate grant - see `tenant-env-rbac-template.yaml`, applied once per
environment (a real gap caught the same way most of this doc's caveats were: by
reasoning through what actually calls what, not by running it and hoping).

## What flows through the broker (Phase 1)

- `dev.cdevents.artifact.published.0.3.0` (from `build`) -> fires `test`
- `dev.cdevents.testcaserun.finished.0.3.0`, `outcome=Succeeded` (from `test`) -> fires
  `deploy`

`deploy -> release` chaining, and `release`'s own event, are Phase 2 (see the plan).
