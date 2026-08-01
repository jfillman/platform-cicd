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

log "0/7 - target the existing kind-observe cluster (not creating a new one)"
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

log "1/7 - cert-manager (TLS for the broker's TokenReview ClusterInterceptor)"
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace --set crds.enabled=true --wait
  kubectl apply -f platform/broker/manifests/cluster-issuer.yaml
else
  echo "cert-manager already installed, skipping"
  kubectl apply -f platform/broker/manifests/cluster-issuer.yaml
fi

log "2/7 - Tekton Pipelines + Triggers + Pipelines-as-Code (not present on kind-observe)"
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl apply -f https://storage.googleapis.com/pipelines-as-code/release/latest/release.yaml
kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=180s
kubectl -n tekton-pipelines-resolvers rollout status deployment/tekton-pipelines-remote-resolvers --timeout=180s
kubectl apply -f observability/kind-observe/tekton-servicemonitor.yaml

log "3/7 - External Secrets Operator (not present on kind-observe)"
if ! kubectl get ns external-secrets >/dev/null 2>&1; then
  helm repo add external-secrets https://charts.external-secrets.io --force-update
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace --wait
else
  echo "external-secrets already installed, skipping"
fi

log "3.5/7 - reused, not (re)installed: ArgoCD (argocd ns), Crossplane (crossplane-system ns),"
echo "        kube-prometheus-stack + Tempo + Loki + Grafana (observability ns) - all already"
echo "        running on kind-observe. See docs/bootstrap.md for what got reused and why."
echo "        The shared OTel Collector there was patched (additively) with a spanmetrics"
echo "        connector - see observability/kind-observe/otel-collector-values-patch.yaml."

log "4/7 - platform catalog namespace + shared Tekton catalog (read-only for tenants)"
kubectl create namespace platform-catalog --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n platform-catalog -f catalog/stepactions/
kubectl apply -n platform-catalog -f catalog/tasks/
kubectl apply -n platform-catalog -f catalog/pipelines/
kubectl apply -f catalog/rbac/catalog-read-only.yaml

log "5/7 - build + load local images (toolbox, token-review-interceptor)"
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

log "6/7 - shared broker (EventListener + TokenReview interceptor)"
kubectl apply -f platform/broker/manifests/interceptor.yaml
kubectl wait --for=condition=Ready certificate/cdevents-broker-auth-tls -n platform-system --timeout=60s
# See the caBundle comment in interceptor.yaml: cert-manager's CA injector doesn't
# support this CRD field, so we patch it directly from the CA cert-manager issued.
CA_BUNDLE="$(kubectl get secret platform-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}')"
kubectl patch clusterinterceptor cdevents-broker-auth --type merge \
  -p "{\"spec\":{\"clientConfig\":{\"caBundle\":\"${CA_BUNDLE}\"}}}"
kubectl apply -f platform/broker/manifests/eventlistener.yaml

log "7/7 - Grafana dashboards, provisioned into the existing Grafana in observability ns"
kubectl apply -k observability/grafana/

log "Done. Next: onboard a pilot repo - see docs/onboarding.md."
echo "Grafana: kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "         (existing admin creds: kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
