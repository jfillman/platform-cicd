# ADR-0002: CDEvents broker with TokenReview auth for inter-stage chaining

## Context

Inter-stage chaining (build finished → start test; test passed → start deploy) isn't
a git event, so Pipelines-as-Code doesn't cover it (see ADR-0001). Something needs to
relay "stage N finished" into "start stage N+1" across independently-triggered
PipelineRuns, for potentially many tenants on a shared cluster, without any tenant
being able to trigger or spoof another tenant's pipeline, and without a platform
component holding a credential broad enough to be a real security liability if
compromised.

## Decision

One shared Tekton Triggers `EventListener` (2-3 replicas, stateless) relays CDEvents
between stages, instead of a per-tenant listener pod. Each stage's `finally` block
emits a CDEvent; a small custom `ClusterInterceptor` authenticates the caller via the
Kubernetes `TokenReview` API against that pod's own cluster-issued, audience-bound
projected ServiceAccount token - no custom key material, no minting server, no
rotation job. Each tenant gets its own `Trigger` CR (a CRD object, not a pod) scoped
to that tenant's own least-privilege namespaced ServiceAccount, so the shared broker
itself never creates a PipelineRun with an elevated identity - the tenant's own SA
does, via a mechanism Tekton Triggers already supports natively.

CDEvents are also the source for DORA metrics (deployment frequency, lead time,
change-failure-rate) - a stateless Go service subscribes as another consumer off the
same broker. MTTR is marked best-effort/experimental in the dashboard rather than
given the same confidence as the other three, since a manual-rollback-outside-the-
pipeline blind spot makes it the metric most likely to quietly become inaccurate.

## Consequences

- No bearer token is ever minted or trusted by the platform itself - compromising the
  broker doesn't hand out a reusable credential, since it delegates every trust
  decision to the Kubernetes API server.
- The broker's own identity has no elevated cluster role - it's checkable directly:
  `kubectl auth can-i --as=system:serviceaccount:<broker-ns>:<broker-sa> '*' '*'`
  should be an emphatic no.
- A shared broker is a single point of chaining for every tenant - it must stay
  cheap and horizontally scalable (stateless, 2-3 replicas), since migrating this
  transport later would be high-blast-radius.
- CDEvents delivery is at-least-once, so idempotent PipelineRun naming and a
  stalled-pipeline detector (expected-next-stage-didn't-start alert) are required
  companions, not optional polish.
