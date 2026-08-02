#!/usr/bin/env bash
# hack/bootstrap.sh
#
# Targets the existing shared `kind-observe` dev cluster rather than creating a
# dedicated one - see docs/bootstrap.md "Why kind-observe, not a fresh cluster" for the
# full reasoning and the tradeoffs that decision carries (most importantly: no
# NetworkPolicy enforcement, see the CNI note below). This script only installs what's
# genuinely missing on that cluster and is careful not to touch anything already owned
# by other workloads there (holmesgpt, order-processing-service, payment-service, the
# existing observability/argocd/crossplane-system stacks).
#
# Idempotent: safe to re-run. Each step checks whether it's already done before acting.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTEXT="kind-observe"
KIND_CLUSTER_NAME="observe" # kind's own name for the cluster, i.e. context minus the "kind-" prefix
CATALOG_IMAGE_TAG="latest"

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }
}

require kubectl
require helm
require docker

log "0/6 - target the existing kind-observe cluster (not creating a new one)"
if ! kubectl config get-contexts -o name | grep -qx "${CONTEXT}"; then
  echo "error: context '${CONTEXT}' not found in your kubeconfig. This script assumes" >&2
  echo "you already have the kind-observe cluster running - it does not create one." >&2
  exit 1
fi
kubectl config use-context "${CONTEXT}"

log "CNI check (informational, not enforced by this script)"
if ! kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q .; then
  warn "kind-observe runs kindnet, not Calico/Cilium - NetworkPolicy objects in this repo"
  warn "(default-deny, allow-from-same-namespace) will be silently NOT enforced. This is a"
  warn "known, accepted gap for this shared dev cluster - see docs/chaining.md 'Tenant"
  warn "isolation' section. TokenReview auth on the broker is the real trust boundary and"
  warn "is unaffected; NetworkPolicy was always meant as defense-in-depth on top of it, not"
  warn "a substitute for it. Swapping the CNI on a live, shared, multi-project cluster is"
  warn "NOT something this script will do - that's a destructive, cluster-wide change"
  warn "affecting every other namespace here, and is out of scope for a repointing exercise."
fi

log "1/6 - Tekton Pipelines + Triggers + Pipelines-as-Code + Dashboard (not present on kind-observe)"
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
# Pipelines-as-Code moved from the openshift-pipelines org to tektoncd, and release
# hosting moved with it - from the old (now-404) GCS bucket to GitHub release assets.
# release.k8s.yaml is the vanilla-Kubernetes variant (release.yaml is OpenShift-flavored
# and includes Route objects that don't exist on kind-observe) - matches this platform's
# "vanilla Kubernetes, no OpenShift" decision. Pinned to a specific version deliberately
# rather than tracking "latest", same reasoning as the tool versions pinned in
# catalog/toolbox/Dockerfile: bump PAC_VERSION here intentionally, don't let a shared
# cluster silently pick up whatever's newest.
#
# v0.49.0 is broken on this cluster's arm64 node: all three PaC deployments (controller/
# watcher/webhook) crash instantly with SIGSEGV (exit 139) and zero log output on every
# start, while Tekton's own pods run fine under the identical restricted securityContext
# on the same node - ruling out a node/kernel/seccomp cause. An arm64 image variant does
# exist for v0.49.0 (confirmed via the GHCR manifest list), so this looks like a real bug
# in that specific release rather than a missing-platform issue. v0.48.1 (chronologically
# newer than v0.49.0 despite the lower version number - a backport release) does not
# reproduce the crash and is what's pinned below. Re-test v0.49.0+ on a future bump.
PAC_VERSION="v0.48.1"
kubectl apply -f "https://github.com/tektoncd/pipelines-as-code/releases/download/${PAC_VERSION}/release.k8s.yaml"
kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=180s
kubectl -n tekton-pipelines-resolvers rollout status deployment/tekton-pipelines-remote-resolvers --timeout=180s
kubectl -n pipelines-as-code rollout status deployment/pipelines-as-code-controller --timeout=180s
kubectl -n pipelines-as-code rollout status deployment/pipelines-as-code-watcher --timeout=180s
kubectl -n pipelines-as-code rollout status deployment/pipelines-as-code-webhook --timeout=180s
kubectl apply -f observability/kind-observe/tekton-servicemonitor.yaml
#
# Tekton Dashboard - deliberately release.yaml (the read-only variant), not
# release-full.yaml (its write-enabled sibling): this platform's whole PaaS model
# is that developers configure pipelines via cicd.yaml and never hand-author or manually
# trigger Tekton resources - a write-enabled dashboard would be a standing bypass around
# that, and would grant its own ServiceAccount create/delete on PipelineRuns/TaskRuns
# across every tenant namespace, which cuts against the "no elevated identity anywhere"
# posture the rest of this platform holds to (see tenant-triggers-template.yaml's
# impersonation-scoping comment). Confirmed by inspecting the manifest directly (not
# assumed from the filename): its RBAC only binds to Tekton's own *-aggregate-view
# ClusterRoles (read on pipelines/pipelineruns/tasks/taskruns/triggers resources) plus
# get/list/watch on events/namespaces/pods/pods-log for the UI/log-streaming, and the one
# write verb it has (create/update/delete on dashboard.tekton.dev Extensions) is scoped to
# its own UI-extension-registration CRD, not pipeline execution. Pinned rather than
# tracking "latest", same reasoning as PAC_VERSION above.
TEKTON_DASHBOARD_VERSION="v0.70.0"
kubectl apply -f "https://github.com/tektoncd/dashboard/releases/download/${TEKTON_DASHBOARD_VERSION}/release.yaml"
kubectl -n tekton-pipelines rollout status deployment/tekton-dashboard --timeout=180s

log "2/6 - External Secrets Operator (not present on kind-observe)"
if ! kubectl get ns external-secrets >/dev/null 2>&1; then
  helm repo add external-secrets https://charts.external-secrets.io --force-update
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace --wait
else
  echo "external-secrets already installed, skipping"
fi

log "2.5/6 - reused, not (re)installed: ArgoCD (argocd ns), Crossplane (crossplane-system ns),"
echo "        kube-prometheus-stack + Tempo + Loki + Grafana (observability ns) - all already"
echo "        running on kind-observe. See docs/bootstrap.md for what got reused and why."
echo "        The shared OTel Collector there was patched (additively) with a spanmetrics"
echo "        connector - see observability/kind-observe/otel-collector-values-patch.yaml."

log "3/6 - platform catalog namespace + shared Tekton catalog (read-only for tenants)"
kubectl create namespace platform-catalog --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n platform-catalog -f catalog/stepactions/
kubectl apply -n platform-catalog -f catalog/tasks/
kubectl apply -n platform-catalog -f catalog/pipelines/
kubectl apply -f catalog/rbac/catalog-read-only.yaml

log "4/6 - build + load local images (toolbox, token-review-interceptor)"
docker build -f catalog/toolbox/Dockerfile -t "ghcr.io/platform-cicd/toolbox:${CATALOG_IMAGE_TAG}" .
docker build -f platform/broker/cmd/token-review-interceptor/Dockerfile \
  -t "ghcr.io/platform-cicd/token-review-interceptor:${CATALOG_IMAGE_TAG}" platform/broker
if command -v kind >/dev/null 2>&1; then
  if ! kind load docker-image "ghcr.io/platform-cicd/toolbox:${CATALOG_IMAGE_TAG}" --name "${KIND_CLUSTER_NAME}"; then
    warn "kind load docker-image failed - known issue with kind's podman provider detection"
    warn "on this machine (see docs/bootstrap.md 'kind + podman'). Fallback: podman save the"
    warn "image and 'kind load image-archive', or push to a registry the cluster can pull from."
  fi
  kind load docker-image "ghcr.io/platform-cicd/token-review-interceptor:${CATALOG_IMAGE_TAG}" --name "${KIND_CLUSTER_NAME}" || true
else
  warn "kind CLI not found or unusable - load these images into the cluster manually:"
  warn "  ghcr.io/platform-cicd/toolbox:${CATALOG_IMAGE_TAG}"
  warn "  ghcr.io/platform-cicd/token-review-interceptor:${CATALOG_IMAGE_TAG}"
fi

log "5/6 - shared broker (EventListener + TokenReview interceptor)"
kubectl apply -f platform/broker/manifests/interceptor.yaml
kubectl apply -f platform/broker/manifests/eventlistener.yaml

log "6/6 - Grafana dashboards, provisioned into the existing Grafana in observability ns"
kubectl apply -k observability/grafana/

log "Done. Next: onboard a pilot repo - see docs/onboarding.md."
echo "Grafana: kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "         (existing admin creds: kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
