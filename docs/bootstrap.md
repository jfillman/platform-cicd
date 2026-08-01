# Bootstrap

`hack/bootstrap.sh` stands up a local `kind` cluster with everything Phase 1 needs, in
dependency order: Calico (NetworkPolicy enforcement), cert-manager, Tekton
Pipelines/Triggers/Pipelines-as-Code, ArgoCD, External Secrets Operator, the
observability stack (kube-prometheus-stack, Tempo, Loki, OTel Collector, Grafana), the
shared catalog, and the broker. It's idempotent - re-run it after pulling changes.

```
./hack/bootstrap.sh
kubectl -n platform-observability port-forward svc/grafana 3000:80
```

## Why Calico, not kind's default CNI

`hack/kind-config.yaml` sets `disableDefaultCNI: true`. kindnet (kind's default) does
**not** enforce `NetworkPolicy` - every `default-deny`/`allow-from-same-namespace`
manifest in this repo would silently do nothing on a stock kind cluster. This is
flagged as a hard platform prerequisite, not a local-only detail, precisely because it's
easy to get a green demo on a cluster where the security model isn't actually being
enforced at all. See [chaining.md](chaining.md) for why NetworkPolicy is defense-in-
depth here rather than the primary trust boundary (that's TokenReview) - but defense-in-
depth that silently doesn't work is worse than not having it, because it looks like it's
there.

## Manual step: the GitHub App

Pipelines-as-Code needs a GitHub App registered against your GitHub org/account, with
webhook delivery pointed at the PaC controller's ingress. This can't be automated from
inside the cluster - see the
[upstream PaC install docs](https://pipelinesascode.com/docs/install/) for the exact
steps (create the App, generate a private key, install it on the pilot repos, configure
the webhook secret as a Kubernetes Secret PaC reads).

## What's different on a real (non-kind) cluster

- Tempo/Loki: swap `storage.trace.backend: local` / `storage.type: filesystem` for an
  object-storage backend (S3-compatible) - local disk in `observability/tempo/values.yaml`
  and `observability/loki/values.yaml` is a kind-only shortcut.
- Ingress/DNS for the PaC controller's webhook endpoint and Grafana - not set up here at
  all; a real cluster needs a real Ingress controller and DNS record.
- `ghcr.io/platform-cicd/*` images need to actually be pushed to a real registry your
  cluster can pull from, instead of `kind load docker-image`.
- Pod Security Standards `restricted` + kaniko: validate this combination on your actual
  target cluster/CNI before onboarding real apps - see [rootless-builds.md](rootless-builds.md).
