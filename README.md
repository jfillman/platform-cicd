# platform-cicd

An internal CI/CD platform on Tekton + Pipelines-as-Code, vanilla Kubernetes. Successor
to an earlier OpenShift/Istio-based platform - see the architecture plan referenced
below for what changed and why.

**Platform-as-a-service model**: application developers write one file,
[`cicd.yaml`](docs/user-guide/cicd-yaml-reference.md), at their repo root. They never
see, write, or edit Tekton YAML. Everything else - triggering, chaining, tracing,
dashboards - is the platform's job. Start at
[docs/user-guide/](docs/user-guide/README.md) if that's you.

## Architecture, in one page

Two distinct triggering mechanisms, because they have genuinely different trust models:

- **Git-sourced events** (push, PR, tag, release, PR-comment ChatOps) are owned entirely
  by **Pipelines-as-Code**. Its GitHub App handles webhook auth and PR status checks
  natively - this is what eliminates the old platform's hand-rolled JWT server and
  generated-GitHub-Actions-workflow machinery outright. Each app repo needs a small,
  platform-generated `.tekton/*.yaml` boilerplate file (PaC's own requirement) -
  developers never hand-write it. See [docs/onboarding.md](docs/onboarding.md).
- **Inter-stage chaining** (build finished -> start test; test passed -> start deploy)
  isn't a git event, so PaC doesn't cover it. A shared internal broker
  ([`platform/broker/`](platform/broker/)) relays CDEvents between independently-
  triggered PipelineRuns, authenticated via each pod's own Kubernetes-issued
  ServiceAccount token (TokenReview) instead of a platform-minted credential. See
  [docs/chaining.md](docs/chaining.md).

Every pipeline step emits OpenTelemetry spans (via `otel-cli`, wrapped in
[`catalog/lib/otel.sh`](catalog/lib/otel.sh)), stitched into **one Tempo trace per
end-to-end flow** even though each stage is a separate PipelineRun - see
[docs/tracing.md](docs/tracing.md). Grafana dashboards
([`observability/grafana/dashboards/`](observability/grafana/dashboards/)) give a live +
historical pipeline list and a per-stage drill-down.

Governance gates (SAST, image scanning, policy checks, SBOM) are **explicit,
structurally-loud stubs** in this phase of the platform, not real enforcement - see
[docs/governance-stubs.md](docs/governance-stubs.md). This is a deliberate reaction to
the old platform's `exit 0` gates that silently always passed.

## Repo layout

```
catalog/          shared Tekton catalog - Pipelines, Tasks, StepActions, bash lib, toolbox image
platform/broker/   the internal CDEvents relay: EventListener + TokenReview interceptor (Go)
observability/     dashboards + reference Helm values; observability/kind-observe/ is what's actually applied (see docs/bootstrap.md)
schemas/           cicd.schema.json - the developer-facing config contract
charts/platform-cicd-app/files/onboarding-templates/app-repo/     boilerplate PaC trigger files delivered to each app repo (via a per-Application ConfigMap, not baked into the toolbox image)
charts/platform-cicd-app/files/onboarding-templates/gitops-repo/  boilerplate PaC governance-check files delivered to each gitops repo (release stage)
hack/              bootstrap against the shared kind-observe dev cluster
docs/              design docs - read chaining.md and tracing.md first
docs/user-guide/   application-developer docs - cicd.yaml reference, quickstart, examples
```

## Getting started

Targets the existing shared `kind-observe` dev cluster - see
[docs/bootstrap.md](docs/bootstrap.md) for what's already there, what gets installed
fresh, and a real gap worth reading before you rely on this cluster's security posture
(no NetworkPolicy enforcement - TokenReview auth on the broker is unaffected, but read
the doc).

```
./hack/bootstrap.sh
# then onboard a pilot repo - see docs/onboarding.md
```

## Status: Phase 1

Current scope is the first demonstrable increment: **build -> test -> deploy-to-dev**,
end to end, with unified tracing and a live dashboard. Deliberately **not yet built**:

- `release` stage / upper-environment promotion (Phase 2)
- PR-based ephemeral environments via ArgoCD ApplicationSet, DORA metrics exporter +
  dashboard, CDEvents delivery reliability (dedup is done; stalled-flow detection isn't)
  (Phase 2)
- Self-service onboarding via Crossplane (`Application` + `PreviewEnvironment` XRDs),
  branch-based ephemeral environments, real implementations behind the governance
  stubs (Phase 3)

Full phase breakdown and the reasoning behind each architectural decision:
[docs/architecture-plan.md](docs/architecture-plan.md) (the approved design plan this
repo implements, including one correction made during implementation).
