# Installation

platform-cicd installs onto any Kubernetes cluster in one of two ways. Pick based on
whether the cluster is GitOps-managed already.

## Option A: declarative, via ArgoCD (preferred for any new cluster)

If the target cluster already runs ArgoCD (or is getting one), install this platform
the same way every other cluster-config piece gets installed: a couple of ArgoCD
`Application` manifests in that cluster's own `gitops-cluster-<name>` repo. See
`gitops-cluster-dev/50-platform-cicd/` for a working reference - it wires up
`tektoncd/operator` (Tekton Pipelines/Triggers/Chains/Dashboard/PaC in one namespace),
`platform-cicd-catalog`, and `platform-cicd-control-plane`.

Steps for a brand-new cluster:

1. Get ArgoCD running on the target cluster (out of scope here - see that cluster's
   own bootstrap).
2. Generate this cluster's own values, writing straight into its `gitops-cluster-<name>`
   repo checkout (not into `platform-cicd` - see that script's own header for why):

   ```
   ./hack/generate-cluster-values.sh <kube-context> <cluster-name> \
     ../gitops-cluster-<name>/50-platform-cicd/platform-cicd-control-plane
   ```

   This reads the cluster's own API server root CA live and generates a fresh,
   independent Fulcio signing root for it - it never copies another cluster's trust
   material. Commit and push the resulting file.
3. Add the two Application manifests (control-plane, catalog) to that repo, each
   multi-source: one source is this platform's chart at `charts/platform-cicd-catalog`
   / `charts/platform-cicd-control-plane`, the other a `directory` source (`exclude:
   "*"`) pointed at the cluster-config repo itself, `$ref`'d for `valueFiles` - see
   `gitops-cluster-dev/50-platform-cicd/platform-cicd-control-plane/application.yaml`
   for the exact shape, and [architecture-decisions](adr/) ADR-0006 for why cluster
   state never lives inside `platform-cicd` itself.
4. Push. ArgoCD takes it from there.

This keeps `platform-cicd` installable standalone on any cluster - it carries zero
cluster-specific secrets or identity in its own repo.

## Option B: imperative, via `hack/bootstrap.sh`

For a cluster that isn't GitOps-managed, or as a one-off/local (`kind`) install:

```
./hack/bootstrap.sh
```

Idempotent, safe to re-run. Installs whatever's genuinely missing (Tekton
Pipelines/Triggers/Pipelines-as-Code, External Secrets Operator, the shared catalog,
the broker) and leaves everything else alone. Retarget with `CONTEXT`/
`KIND_CLUSTER_NAME` env vars for a different cluster; a per-cluster values file at
`hack/values-<context>.yaml` is auto-discovered if present (see
`hack/generate-cluster-values.sh`, run with no third argument to write there instead
of into a gitops repo).

Grafana serves the platform's own dashboards (rendered as ConfigMaps by the
control-plane chart, not a separate apply step). The Tekton Dashboard is the
complementary low-level view - installed **read-only** deliberately, matching this
platform's PaaS/RBAC posture.

## Operational notes that apply either way

- **NetworkPolicy needs a real CNI.** `default-deny`/`allow-from-same-namespace`
  manifests are silent no-ops on a CNI that doesn't enforce `NetworkPolicy` (e.g.
  kindnet). TokenReview authentication on the broker - not NetworkPolicy - is the
  actual trust boundary (see [chaining.md](chaining.md)); NetworkPolicy is
  defense-in-depth on top of it. Pin a Calico/Cilium-class CNI for anything beyond a
  shared dev cluster.
- **The GitHub App needs a public endpoint.** Pipelines-as-Code's webhook delivery
  can't reach a local/private cluster directly - front the PaC controller with a
  tunnel (`cloudflared`, `ngrok`) for local dev, or real ingress/DNS for anything else.
- **`token-review-interceptor`/`argocd-outcome-relay` images are `IfNotPresent` +
  `:latest`.** A source change under `platform/broker/cmd/` does nothing to a running
  cluster until you rebuild, push, and `kubectl rollout restart` the affected
  Deployment - there's no CI wired to a private cluster to do this automatically.
- **Pod Security Standards `restricted` + kaniko**: validate this combination against
  your actual target CNI before onboarding real apps - see
  [rootless-builds.md](rootless-builds.md).

## Upper environments (staging/prod)

A separate bootstrap, covered in [multi-cluster.md](multi-cluster.md) -
`hack/bootstrap-upper-cluster.sh` installs just ArgoCD on a target cluster; this
platform's own Tekton/broker never runs there.
