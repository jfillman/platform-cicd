# Tekton + Pipelines-as-Code CI/CD Platform — Architecture & Build Plan

> Copied verbatim into the repo from the approved design plan so it travels with the
> code instead of only living at `~/.claude/plans/shimmering-noodling-lemon.md` on one
> machine. This is the reasoning record - `README.md` and the `docs/*.md` files it links
> to are the living, kept-current documentation; this file is the historical decision
> record and won't be updated as the implementation evolves.

## Context

You built a Tekton-based CI/CD platform once before (`gitops-main/charts/cd-pipelines` + `cd-pipelines-user`, on OpenShift/Istio/Azure). An audit of that system found real strengths worth keeping — a declarative per-app pipeline config DSL, CDEvents-decoupled multi-stage pipelines, ArgoCD's native PR generator for ephemeral environments, dev→prod image promotion by digest — alongside real problems worth fixing, not repeating:

- A hand-rolled JWT-minting server + CronJob + generated-GitHub-Actions-workflow machinery existed purely to work around classic Tekton Triggers not having native git-webhook auth.
- The control-plane pipeline ServiceAccount held cluster-wide SA impersonation **and** a `cluster-admin` ClusterRoleBinding — one compromised component was a full cluster compromise.
- Half the named quality gates (QA, gatekeeper, image-scan-check, SAST-check, ArgoCD-health) were literal `exit 0` stubs reported as if they were real checks — governance theater.
- Zero observability: no tracing, no metrics, no dashboards, no DORA data anywhere.

This plan designs the successor: Tekton + **Pipelines-as-Code**, vanilla Kubernetes (portable, no OpenShift/Istio/Azure lock-in), platform-as-a-service model where developers configure pipelines through one simple file and never touch Tekton YAML, full OpenTelemetry tracing surfaced in Grafana with per-stage drill-down, DORA metrics, and ephemeral environments (branch- and PR-based) as first-class features. Scope was explicitly narrowed by you to **enterprise-scale multi-tenant, core-platform-first** — real quality gates are deferred to a later phase, built as clearly-marked stub extension points rather than repeating the old silent-`exit 0`-theater problem.

The architecture below was drafted, then independently pressure-tested by a design-review pass that changed three load-bearing decisions from the first draft: a single shared event broker instead of one EventListener pod per tenant, dropping a "sync config to ConfigMap" mechanism in favor of always reading config fresh from the triggering commit, and treating DORA's MTTR metric as best-effort/experimental rather than presenting it with the same confidence as the other three DORA metrics. Those revisions are incorporated directly below, not left as open alternatives.

---

## Architecture Overview

Two kinds of triggering, deliberately split by mechanism because they have genuinely different trust models:

**Git-sourced triggers (push, PR, tag, release, PR-comment ChatOps)** are owned entirely by **Pipelines-as-Code**. PaC's own GitHub App handles webhook signature validation, PR status checks, and `/retest`-style comments — this is what eliminates the old JWT server and generated-workflow-file machinery outright. PaC requires a small `.tekton/*.yaml` file physically present in each app repo; that file is **pure boilerplate**, generated once at onboarding, referencing the shared Pipeline catalog via Tekton's cluster resolver. It is not something a developer hand-writes or edits.

**Inter-stage chaining (build → test → deploy → release)** is not a git event — it's "stage N finished, start stage N+1" — so PaC doesn't cover it. This stays CDEvents-decoupled (each stage's `finally` block emits a CDEvent) exactly like the old system's core idea, but the transport is redesigned: **one shared Tekton Triggers EventListener** (2–3 replicas, stateless, cheap to run at HA) instead of per-app pods. Authentication uses each pipeline pod's own cluster-issued, audience-bound projected ServiceAccount token, verified via a small custom `ClusterInterceptor` calling the Kubernetes TokenReview API — no custom key material, no minting server, no rotation CronJob. Each tenant gets its own `Trigger` CR (a cheap CRD object, not a pod) with `serviceAccountName` scoped to that tenant's own least-privilege namespaced SA, so the shared broker itself never creates a PipelineRun with an elevated identity — the tenant's own SA does, via a mechanism Tekton Triggers already supports natively.

**Developer-facing config** is a single human-edited file in the app's repo (`cicd.yaml`) — build agent/image, test command, deploy targets, ephemeral-env settings, notification targets — read fresh by the first Task in every pipeline run, directly from the triggering commit, and validated against a JSON Schema with fail-fast, developer-readable errors. No separate sync-to-ConfigMap subsystem, no second source of truth. For v1 this drives a **fixed superset Pipeline DAG** with `when:`-guarded stages (toggle/parameterize, not arbitrary graphs) — a full `cicd.yaml`-to-generated-Pipeline compiler is a materially heavier pattern and is explicitly out of scope until there's real evidence it's needed.

**Tracing**: no Tekton-native per-step span emission exists, so a shared bash helper (wrapping `otel-cli`, packaged as reusable **StepActions** in the catalog rather than copy-pasted per Task) creates/ends a span around each step. A W3C `traceparent` is established once per PipelineRun and threaded through Task params/results; it's also carried inside the CDEvent payload (as a distinct extension field, kept separate from CDEvents' own `chainId` correlation field) so independently-triggered PipelineRuns across the whole build→release flow land in Grafana Tempo as **one trace**, each stage parented directly to the flow root (flat, not nested — stages don't temporally overlap, so nesting would misrepresent duration).

**DORA metrics** are sourced from the CDEvents stream specifically (not derived from spans) — CDEvents is a required-to-function channel with loud failure, traces are observability with silent-failure risk, and DORA numbers should come from the channel that fails loudly. A small stateless Go service subscribes as another consumer off the same shared broker and exposes Prometheus counters/histograms for deployment frequency, lead time, and change-failure-rate. **MTTR is explicitly marked best-effort/experimental** in the dashboard (visually distinct from the other three) rather than deferred entirely, because a manual-rollback-outside-the-pipeline blind spot makes it the most likely metric to quietly become inaccurate.

**Crossplane** is used, but scoped honestly rather than because you like the tool: a `PreviewEnvironment` XRD is the flagship use — ephemeral environments legitimately want more than K8s manifests (a scoped, TTL'd resource composed alongside the namespace), which is something Crossplane does that Helm+ArgoCD structurally can't.

**Update, Phase 3 item 7 (2026-08-06):** the `Application` XRD described in this doc's original draft — namespace, RBAC, `Trigger` CR, PaC `Repository`, ArgoCD `AppProject` for Application onboarding — was superseded by three Helm charts (`charts/platform-cicd-{control-plane,catalog,app}`) before it was ever built, once hand-onboarding a few pilots surfaced a real, live-confirmed gap a Helm chart could close directly: `cicd.yaml`'s `pipeline:` field was schema-validated but never actually enforced (a `release` PipelineRun once fired for an Application that never declared a release stage). This is a narrow scope decision, not a reversal of the Crossplane bet above — Crossplane remains the right tool, untouched, for the one case this doc already argued is genuinely Crossplane-justified: the `PreviewEnvironment` XRD for branch-based ephemeral environments with real cloud-resource composition. Helm only displaces Crossplane for Application *pipeline-plumbing* onboarding (Triggers, RBAC, ArgoCD release wiring, governance config) — see [onboarding.md](onboarding.md) and [catalog-versioning.md](catalog-versioning.md). Today's onboarding is still admin-run (`helm install <app-name> ...`), not genuine self-service; an ArgoCD ApplicationSet git generator scanning a `Applications/*.yaml` directory is the named, not-yet-built path to that.

**Retained from the old system, largely as-is**: ArgoCD for GitOps CD; dev→prod image promotion by digest (never rebuild for prod); PR-based ephemeral environments via ArgoCD ApplicationSet's native `pullRequest` generator (it already worked well and needs no new code); External Secrets Operator, with the Azure Key Vault backend swapped for a pluggable/generic one.

**Security model fix**: no cluster-admin, no SA impersonation, anywhere. Every tenant gets namespace-scoped RBAC only. The shared broker authenticates callers via TokenReview instead of trusting a bearer token it minted itself. NetworkPolicy (default-deny + allow-from-same-namespace, a pattern worth keeping from the old system) is defense-in-depth, not the primary trust boundary — this requires a CNI that actually enforces NetworkPolicy (Calico/Cilium), which is a hard platform prerequisite to pin explicitly, not an implicit assumption.

> Implementation note: the security-model claim above ("no SA impersonation, anywhere")
> turned out to be slightly too absolute once the broker was actually built - see
> [chaining.md](chaining.md) for the corrected, more precise version (scoped,
> per-app, individually-revocable impersonation grants, vs. the old platform's single
> cluster-wide one). The plan's underlying intent - no cluster-admin, no broad grants -
> held; the "zero impersonation" phrasing didn't survive contact with how Tekton
> Triggers actually hands off to a Trigger's ServiceAccount.

---

## Repo Layout

```
platform-cicd/
├── catalog/                # shared Tekton catalog — the only place Applications get read access to
│   ├── pipelines/           # build.yaml, test.yaml, deploy.yaml, release.yaml
│   ├── tasks/                # build-image (kaniko), run-tests, deploy-manifests, send-cdevent, ...
│   ├── stepactions/          # otel-span-start/end, notify-slack, governance-stub, ...
│   └── lib/                  # bash helpers (otel.sh, cdevents.sh) baked into a shared toolbox image
├── platform/
│   ├── broker/                # shared EventListener, TokenReview ClusterInterceptor, per-app Trigger template
│   ├── dora-exporter/          # (Phase 2) CDEvents subscriber -> Prometheus metrics (Go)
│   └── onboarding/              # (Phase 3) Crossplane XRDs/Compositions: Application, PreviewEnvironment
├── observability/
│   ├── otel-collector/
│   ├── tempo/ · loki/ · kube-prometheus-stack/   (Helm values overlays)
│   └── grafana/dashboards/     # pipelines-overview.json, pipeline-detail.json, (Phase 2) dora.json
├── schemas/cicd.schema.json    # JSON Schema for the developer-facing cicd.yaml
├── charts/platform-cicd-catalog/files/onboarding-templates/   # boilerplate PaC trigger files, delivered via ConfigMap
└── docs/
```

---

## Build Sequence

**Phase 0 — Foundations** (prerequisite, not independently demonstrable)
- Pin a NetworkPolicy-enforcing CNI (Calico or Cilium); validate Pod Security Standards `restricted` compatibility with a rootless image-build tool (kaniko, the more battle-tested rootless-in-k8s option vs. buildah-rootless) *now* — this is painful to discover mid-catalog-build.
- Install Tekton Pipelines + Triggers + Pipelines-as-Code; register a GitHub App; install kube-prometheus-stack + Loki + Tempo + OTel Collector; install ArgoCD + External Secrets Operator with one concrete backend.
- Scaffold the catalog repo/namespace with locked-down RBAC: Applications get cluster-resolver **read-only** access, never write.
- Local dev/demo target: `kind`, matching the "vanilla Kubernetes" decision.
- **Status: scaffolded.** `hack/bootstrap.sh` automates this end to end for local `kind`; see [bootstrap.md](bootstrap.md) for what a real cluster needs on top.

**Phase 1 — First demonstrable increment**
- Minimum real chain: **build → test → deploy-to-dev** (build-only doesn't exercise chaining, which is the architecture's core bet).
- Shared broker + TokenReview interceptor + per-app `Trigger` CRs, built correctly now (migrating this transport later is high-blast-radius).
- `.tekton/*.yaml` boilerplate hand-generated for 2–3 pilot repos (full Crossplane self-service is a Phase 3 concern).
- `cicd.yaml` v1 schema + fail-fast validation Task; fixed superset DAG with `when:` toggles.
- OTel: prove root-span + `traceparent` threading **within a single PipelineRun** first, before tackling cross-PipelineRun stitching — a separable, lower-risk milestone.
- Grafana: live + historical PipelineRun list with per-stage drill-down for one pipeline. This alone is a legitimately demoable deliverable.
- Governance stub Tasks wired into the DAG from day one, with stub-ness made structurally loud (a `governance.stub=true` result/span attribute, rendered visually distinct in Grafana) — a direct, deliberate callback to the old system's silent-`exit 0` problem.
- **Status: scaffolded.** Catalog, broker, dashboards, and docs are written; not yet run against a real cluster - see "Next actions" below.

**Phase 2 — Full chaining + ephemeral envs + DORA**
- Extend chaining and trace-stitching across the full build→test→deploy→release sequence.
- Port PR-based ephemeral environments via ArgoCD ApplicationSet's `pullRequest` generator (cheap, high-value, doesn't depend on Crossplane).
- CDEvents idempotency/dedup (deterministic PipelineRun naming from the CDEvent id - **done, built into `send-cdevent`/`charts/platform-cicd-app/templates/triggers/flow-triggers.yaml`**) and a stalled-pipeline detector (expected-next-stage-didn't-start-within-N-minutes alert - done, see `docs/stalled-pipeline-detector.md`), since at-least-once delivery is a real gap otherwise.
- DORA exporter + Grafana DORA panel row, MTTR visually marked experimental.

**Phase 3 — Self-service onboarding + branch-based ephemeral envs + real governance**
- Application onboarding, informed by however the hand-onboarded pilots actually varied - **done as three Helm charts, not a Crossplane `Application` XRD, per the Phase 3 item 7 update above.**
- Crossplane `PreviewEnvironment` XRD for branch-based ephemeral envs, including genuine cloud-resource composition (e.g. a scoped ephemeral DB per env) — the sharpest real justification for Crossplane in this design.
- Real implementations behind the Phase-1 governance stub interfaces (SAST, policy-as-code, image scanning, Enterprise-Contract-style attestation, registry immutability), plus the upper-env PR-gated promotion workflow, ported without the old OpenShift/Istio-specific pieces.

---

## Verification

- **Phase 1 exit test**: push a commit to a pilot repo → PaC fires the build Pipeline → build's `finally` CDEvent (with `traceparent` + `chainId`) flows through the shared broker → tenant's own `Trigger`/SA creates the test PipelineRun → same for deploy-to-dev → `kubectl get pipelineruns -n <tenant>` shows all three completed, and the Grafana dashboard shows one trace spanning all three stages with correct per-stage durations, plus the tenant's `cicd.yaml` change (e.g. toggling a stage) takes effect on the very next push with no manual sync step.
- **Security check**: confirm no tenant SA can list/create resources outside its own namespace, and that the shared broker's own identity has no elevated cluster role (`kubectl auth can-i --as=system:serviceaccount:<broker-ns>:<broker-sa> '*' '*'` should be an emphatic no).
- **Governance-stub check**: a stub gate should be visibly distinguishable from a real one in the Grafana dashboard, not just in code comments — confirm this before Phase 1 is called done, since it's the direct fix for the old system's worst finding.

## Next actions (not yet done)

Everything above is written as code/config/docs but has not been run against a real
cluster. Before calling Phase 1 actually done, not just scaffolded:

1. Run `hack/bootstrap.sh` against a real kind cluster and fix whatever breaks - several
   pieces are flagged in code comments as "verify against the pinned version" (otel-cli
   flags in `catalog/lib/otel.sh`, Tekton Triggers' `serviceAccountName` hand-off
   mechanism in `docs/chaining.md`) precisely because they weren't independently
   confirmed while writing this.
2. Register a real GitHub App for Pipelines-as-Code and onboard one real pilot repo
   end to end (see `docs/onboarding.md`).
3. Run the Phase 1 exit test above for real and fix the gap it surfaces.
