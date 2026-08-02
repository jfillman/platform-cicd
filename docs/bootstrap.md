# Bootstrap

`hack/bootstrap.sh` targets the existing shared `kind-observe` dev cluster rather than
creating a dedicated one. It installs only what's genuinely missing there (Tekton
Pipelines/Triggers/Pipelines-as-Code, External Secrets Operator, the shared catalog, the
broker) and reuses everything else already running. It's idempotent - re-run it after
pulling changes.

```
./hack/bootstrap.sh
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
```

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
| Tekton Pipelines/Triggers/PaC | - | Not present, installed by bootstrap.sh |
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
NetworkPolicy - is what actually prevents cross-tenant traffic; NetworkPolicy was always
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

This machine's `kind` CLI fails to talk to its container provider
(`kind get clusters` / `kind load docker-image` error out against podman - a tooling
bug, not a platform-cicd issue). `hack/bootstrap.sh` treats `kind load docker-image`
failures as non-fatal and warns rather than aborting; if it fails for you too, load the
`ghcr.io/platform-cicd/toolbox` and `ghcr.io/platform-cicd/token-review-interceptor`
images into the cluster manually (`podman save` + `kind load image-archive`, or push to
a registry the cluster can pull from) before continuing.

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
- `ghcr.io/platform-cicd/*` images need to actually be pushed to a real registry your
  cluster can pull from, instead of `kind load docker-image`.
- Pod Security Standards `restricted` + kaniko: validate this combination on your actual
  target cluster/CNI before onboarding real apps - see [rootless-builds.md](rootless-builds.md).
