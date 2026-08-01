#!/usr/bin/env bash
# hack/bootstrap.sh
#
# Phase 0 foundations, automated: stands up a local kind cluster with everything this
# platform depends on, in dependency order. This is a local dev/demo bootstrap, not a
# production install method - see docs/bootstrap.md for what's different about a real
# cluster (real storage classes, real DNS/ingress, a real GitHub App, object-storage
# backends for Tempo/Loki instead of local disk).
#
# Idempotent: safe to re-run. Each step checks whether it's already done before acting.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLUSTER_NAME="platform-cicd"

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }
}

require kind
require kubectl
require helm
require docker

log "1/9 - kind cluster (CNI disabled - Calico installed next, see kind-config.yaml)"
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --config hack/kind-config.yaml
else
  echo "cluster '${CLUSTER_NAME}' already exists, skipping"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

log "2/9 - Calico (NetworkPolicy enforcement is a hard platform prerequisite, not optional)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=180s

log "3/9 - cert-manager (TLS for the broker's TokenReview ClusterInterceptor)"
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait

log "4/9 - Tekton Pipelines + Triggers + Pipelines-as-Code"
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl apply -f https://storage.googleapis.com/pipelines-as-code/release/latest/release.yaml
kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=180s
kubectl -n tekton-pipelines-resolvers rollout status deployment/tekton-pipelines-remote-resolvers --timeout=180s

log "5/9 - ArgoCD + External Secrets Operator"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --wait
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace --wait

log "6/9 - Observability: kube-prometheus-stack, Tempo, Loki, OTel Collector, Grafana"
kubectl create namespace platform-observability --dry-run=client -o yaml | kubectl apply -f -
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n platform-observability -f observability/kube-prometheus-stack/values.yaml --wait
helm upgrade --install tempo grafana/tempo -n platform-observability -f observability/tempo/values.yaml --wait
helm upgrade --install loki grafana/loki -n platform-observability -f observability/loki/values.yaml --wait
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n platform-observability -f observability/otel-collector/values.yaml --wait
helm upgrade --install grafana grafana/grafana -n platform-observability -f observability/grafana/values.yaml --wait
kubectl apply -k observability/grafana/

log "7/9 - platform catalog namespace + shared Tekton catalog (read-only for tenants)"
kubectl create namespace platform-catalog --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n platform-catalog -f catalog/stepactions/
kubectl apply -n platform-catalog -f catalog/tasks/
kubectl apply -n platform-catalog -f catalog/pipelines/
kubectl apply -f catalog/rbac/catalog-read-only.yaml

log "8/9 - build + load local images into kind (toolbox, token-review-interceptor)"
docker build -f catalog/toolbox/Dockerfile -t ghcr.io/platform-cicd/toolbox:latest .
docker build -f platform/broker/cmd/token-review-interceptor/Dockerfile \
  -t ghcr.io/platform-cicd/token-review-interceptor:latest platform/broker
kind load docker-image ghcr.io/platform-cicd/toolbox:latest --name "${CLUSTER_NAME}"
kind load docker-image ghcr.io/platform-cicd/token-review-interceptor:latest --name "${CLUSTER_NAME}"

log "9/9 - shared broker (EventListener + TokenReview interceptor)"
kubectl apply -f platform/broker/manifests/interceptor.yaml
kubectl apply -f platform/broker/manifests/eventlistener.yaml

log "Done. Next: onboard a pilot repo - see docs/onboarding.md."
echo "Grafana: kubectl -n platform-observability port-forward svc/grafana 3000:80"
