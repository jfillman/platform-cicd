# Bootstrap

This covers the dev cluster only. Upper-env clusters (staging/prod-tier, where release
promotions actually land) are a separate bootstrap - see
[hack/bootstrap-upper-cluster.sh](../hack/bootstrap-upper-cluster.sh) and
[multi-cluster.md](multi-cluster.md).

`hack/bootstrap.sh` targets the existing shared `kind-observe` dev cluster by default
rather than creating a dedicated one. It installs only what's genuinely missing there
(Tekton Pipelines/Triggers/Pipelines-as-Code, External Secrets Operator, the shared
catalog, the broker) and reuses everything else already running. It's idempotent -
re-run it after pulling changes.

```
./hack/bootstrap.sh
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097
```

**Second, independent instance on `kind-dev` (2026-08-15)** - a real, separate cluster
(idp's own dev cluster, not related to `kind-observe` despite the similar name), needed
so idp's `NodeJSApplication`-provisioned apps get a real CICD pipeline. `CONTEXT`/
`KIND_CLUSTER_NAME`/`CATALOG_IMAGE_TAG` are all overridable via env var (defaults
reproduce `kind-observe`'s exact current behavior, so a plain `./hack/bootstrap.sh` is
unchanged); the chart-level per-cluster values (Fulcio CA/root cert - each instance gets
its own independently-generated root, never shared - `tenantsRepoUrl`, the
`tenant-onboarding` `ApplicationSet`'s own name) live in a `VALUES_FILE`:

```
CONTEXT=kind-dev KIND_CLUSTER_NAME=dev VALUES_FILE=hack/values-kind-dev.yaml ./hack/bootstrap.sh
```

See `charts/platform-cicd-control-plane/values.yaml`'s own `fulcio`/`tenantsRepoUrl`/
`tenantOnboardingApplicationSetName`/`selfManageNamespace` comments for why each one is a
value instead of a template literal, and `hack/values-kind-dev.yaml` for `kind-dev`'s
actual resolved overrides. `kind-dev`'s tenant list lives in its own dedicated repo,
[platform-cicd-kind-dev-tenants](https://github.com/jfillman/platform-cicd-kind-dev-tenants)
- deliberately not this repo's own `tenants/`, which `kind-observe`'s instance still
reads, to avoid one cluster's install onboarding the other's real, live tenants.

Grafana is for the platform's own dashboards (DORA-ish stats, trace-based durations - see
`charts/platform-cicd-control-plane/files/dashboards/`, rendered as ConfigMaps by
`templates/grafana/dashboards-configmap.yaml` as part of this same chart's release - not
a separate apply step). The Tekton Dashboard (`localhost:9097` above) is
the complementary, lower-level view: live/historical PipelineRuns and TaskRuns across
every Application's namespace, with step-by-step logs - useful for debugging a specific run
without `kubectl get/describe/logs`-ing it by hand. Installed **read-only**
(`release.yaml`, not `release-full.yaml`) deliberately - see the comment in
`hack/bootstrap.sh`'s Tekton install step for why a write-enabled dashboard would cut
against this platform's PaaS model and RBAC posture. Verified live: its ServiceAccount
can `list`/`get` PipelineRuns cluster-wide but not `create`/`delete` them
(`kubectl auth can-i ... --as=system:serviceaccount:tekton-pipelines:tekton-dashboard`).

## Why kind-observe, not a fresh cluster

The platform was originally designed against a dedicated `kind` cluster (see
`hack/kind-config.yaml`, still present as a reference for that path). In practice,
`kind-observe` - an existing cluster already running other projects
(`holmesgpt`, sample `order-processing-service`/`payment-service` workloads) - already
had most of Phase 0's foundations installed, so bootstrap.sh was repointed at it instead
of standing up a redundant second cluster. As of the last audit, kind-observe already
had:

| Component | Namespace | Reused as-is? |
|---|---|---|
| ArgoCD | `argocd` | Yes - not needed for Phase 1's `kubectl`-based deploy, available for Phase 2/3 GitOps flows |
| Crossplane | `crossplane-system` | Present, unused until Phase 3 (`Application`/`PreviewEnvironment` XRDs) |
| Argo Rollouts | `argo-rollouts` | Present, pairs with `cicd.yaml`'s `deploy.strategy: rollout` option |
| kube-prometheus-stack (+ bundled Grafana) | `observability` | Yes - same `grafana_dashboard: "1"` sidecar convention this repo already used, same datasource UIDs (`prometheus`/`tempo`/`loki`) our dashboard JSONs already reference |
| Tempo | `observability` | Yes - backed by Minio (S3-compatible), nicer than this repo's local-disk reference config |
| Loki | `observability` | Yes - Grafana datasource already has trace-ID log correlation (`derivedFields`) pre-wired |
| OTel Collector | `observability` | Yes, additively patched with a spanmetrics connector - see `observability/kind-observe/otel-collector-values-patch.yaml` |
| Project Contour (ingress) | `projectcontour` | Present, not yet used - see "Manual step: the GitHub App" below |
| Tekton Pipelines/Triggers/PaC/Dashboard | - | Not present, installed by bootstrap.sh |
| External Secrets Operator | - | Not present, installed by bootstrap.sh |

`observability/*/values.yaml` (kube-prometheus-stack, tempo, loki, grafana,
otel-collector) are kept in the repo as reference configs for a cluster that does *not*
already have this stack - bootstrap.sh does not apply them against kind-observe. The
actual applied config for the one thing that needed changing (the collector) lives in
`observability/kind-observe/`.

If you ever do want a fully isolated cluster instead (no shared state with other
projects), `hack/kind-config.yaml` plus a Calico install (see below) is that path - it's
just not what bootstrap.sh does today.

## The NetworkPolicy gap - read this before treating this cluster as a security reference

kind-observe runs **kindnet**, not Calico/Cilium. kindnet does **not** enforce
`NetworkPolicy` - every `default-deny`/`allow-from-same-namespace` manifest in this repo
is silently a no-op here. `hack/bootstrap.sh` detects and warns about this at runtime; it
does not try to fix it.

This is a deliberate, accepted tradeoff, not an oversight: swapping the CNI on a live,
shared, multi-project cluster is a destructive, cluster-wide change affecting every other
namespace on it (`holmesgpt`, `demo`, `demo-apps`, ArgoCD, Crossplane, the sample
services) - recreating the CNI on a running cluster isn't a clean operation, and this
repo will not do it as a side effect of a bootstrap script. Functionally, the platform's
actual security boundary holds regardless: as documented in
[chaining.md](chaining.md), TokenReview authentication on the broker - not
NetworkPolicy - is what actually prevents cross-app traffic; NetworkPolicy was always
meant as defense-in-depth layered on top of it. What's genuinely lost here is that
second layer, on this cluster only. Don't extend that assumption to a real/production
target without re-adding a NetworkPolicy-enforcing CNI there.

## The broker's TokenReview interceptor runs plain HTTP, not HTTPS

This was originally TLS-terminated with a cert-manager self-signed CA, the standard
pattern (matching how Tekton's own built-in ClusterInterceptors are configured via
`spec.clientConfig.caBundle`). It was dropped after extensive live debugging: the
EventListener sink rejected the cert on every call
(`x509: certificate signed by unknown authority`) despite confirming the CA genuinely
issued the serving cert, ruling out a stale informer cache (recreated the
`ClusterInterceptor` from scratch, restarted the sink), and hitting a hard wall trying
to get the CA into the sink pod's own trust store - blocked outright by the
`EventListener` CRD's admission webhook when attempted through the CRD's own pod-template
override, then silently reverted by the EventListener's reconciler when patched directly
onto the generated `Deployment`. See the comment at the top of
`platform/broker/cmd/token-review-interceptor/main.go` for the full account.

This is a real, deliberate tradeoff, not a hidden one: as covered in the NetworkPolicy
section above, TokenReview-verified caller identity - not transport TLS - was always the
actual trust boundary for this internal, never-leaves-the-cluster call. Losing transport
encryption here is a smaller version of the same accepted gap. Revisit if this needs to
run somewhere the `caBundle` mechanism can be made to work, or if a later Tekton Triggers
version behaves differently.

## token-review-interceptor/argocd-outcome-relay: rebuild+restart after touching source

**Registry-published as of 2026-08-16** (`ghcr.io/jfillman/platform-cicd-token-review-
interceptor`/`-argocd-outcome-relay`), fixing a real reproducibility gap: both used to
reference `ghcr.io/platform-cicd/...`, an org that doesn't exist (confirmed live -
`docker pull` → "manifest unknown", `gh api orgs/platform-cicd` → 404) - only ran at all
via images loaded onto a node by hand, off-script, at some point in the past.
token-review-interceptor had a documented `kind load` step at least; argocd-outcome-relay
had no build/load mechanism anywhere, and was silently surviving on kind-observe purely
on a stale locally-cached image (a fresh install anywhere else would have hit
`ImagePullBackOff` immediately - see the git history around this note for the full
finding).

**The staleness risk below is NOT fixed by that** - it was never actually about
kind-load vs. a real registry, it's `IfNotPresent` + a floating `:latest` tag: once a
node has pulled (or loaded) an image under that tag once, `IfNotPresent` means it never
re-pulls just because a new one was pushed. A source change to
`platform/broker/cmd/token-review-interceptor/` (or `argocd-outcome-relay/`) still does
nothing to the live Deployment until someone re-runs the rebuild+push+restart sequence.

Hit live and confirmed as the root cause of a real incident: commit `c83b479` ("refactor:
remove tenent") renamed the CEL extension this interceptor sets from
`extensions.tenant_namespace` to `extensions.app_namespace`, matching every Trigger's own
CEL filter (`charts/platform-cicd-app/templates/triggers/flow-triggers.yaml`) - but the
running interceptor binary predated that commit, so it kept setting the OLD key. Every
Trigger's `extensions.app_namespace == '<namespace>'` check silently evaluated to false
forever after - not an error PaC/Tekton logs, just a filter that never matches - so the
entire CDEvents broker chain (build -> test -> deploy -> release) stopped firing for
every Application on the cluster, discovered only when a fresh app's first-ever chained
event never produced a downstream PipelineRun. `body.context.source.startsWith(...)`-only
filters (no `extensions.*` reference) kept working throughout, which is what made this
easy to misdiagnose as a CEL/RBAC/payload-validation problem instead - none of those were
actually broken.

Fix: `docker build` + `docker push` + `kubectl rollout restart
deployment/cdevents-broker-auth -n platform-system` (or `deployment/argocd-outcome-relay`
for that image) - the same steps `hack/bootstrap.sh` step 4/5 already does, just not
something anything else triggers automatically. Re-run that step (or at least the
relevant image's rebuild+push+restart) after ANY change to
`platform/broker/cmd/token-review-interceptor/` or `.../argocd-outcome-relay/`, not just
once at initial bootstrap - this repo has no CI/CD of its own to catch the drift otherwise (see
`.github/workflows/catalog-ci.yaml`'s own header for why: no public endpoint for
GitHub-hosted runners to reach this cluster).

## Manual step: the GitHub App

Pipelines-as-Code needs a GitHub App registered against your GitHub org/account, with
webhook delivery pointed at the PaC controller's ingress. This can't be automated from
inside the cluster. kind-observe already has Project Contour installed
(`projectcontour` namespace) but no `IngressClass` registered yet and no public
DNS/reachability - GitHub's webhook servers can't reach a local kind cluster regardless
of what's installed inside it, so for now this still needs a tunnel (`cloudflared`,
`ngrok`, `smee.io`) in front of the PaC controller Service, same as it would on a fully
fresh cluster. See the
[upstream PaC install docs](https://pipelinesascode.com/docs/install/) for the exact
app-creation steps.

## kind + podman

This machine's `kind` CLI fails to talk to its container provider (`kind get clusters` /
`kind load docker-image` error out against podman - a tooling bug, not a platform-cicd
issue). No longer a bootstrap blocker as of 2026-08-16: step 4/5 no longer calls `kind
load docker-image` for anything - all four of its images (`platform-cicd-toolbox`,
`-dora-exporter`, `-token-review-interceptor`, `-argocd-outcome-relay`) are now
`docker push`ed to `ghcr.io/jfillman` instead (see the section above). Kept here as a
known-issue note in case `kind load` is ever needed again for something else.

## What's different on a real (non-kind-observe) cluster

- None of the "already installed" reuse above applies - install kube-prometheus-stack,
  Tempo, Loki, the OTel Collector, and Grafana from scratch using the values files under
  `observability/*/` (not `observability/kind-observe/`, which is specific to patching
  kind-observe's existing release).
- Tempo/Loki: swap `storage.trace.backend: local` / `storage.type: filesystem` for an
  object-storage backend (S3-compatible) - local disk in those reference values files is
  a kind-only shortcut.
- A real, enforced NetworkPolicy-capable CNI (Calico/Cilium) - see the gap noted above.
- Ingress/DNS for the PaC controller's webhook endpoint and Grafana - not set up here at
  all; a real cluster needs a real Ingress controller and DNS record instead of a tunnel.
- Pod Security Standards `restricted` + kaniko: validate this combination on your actual
  target cluster/CNI before onboarding real apps - see [rootless-builds.md](rootless-builds.md).
