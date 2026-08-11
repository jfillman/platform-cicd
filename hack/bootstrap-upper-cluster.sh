#!/usr/bin/env bash
# hack/bootstrap-upper-cluster.sh
#
# Bootstraps an "upper environment" cluster (staging/prod-tier - anything release steps
# can target via cicd.yaml's cluster: field, see docs/multi-cluster.md) with a pinned
# ArgoCD install. Companion to hack/bootstrap.sh, which provisions the dev cluster
# (kind-observe) - this script is deliberately separate rather than a mode flag on that
# one, since the two clusters install almost entirely disjoint things (Tekton/PaC/the
# broker vs. just ArgoCD) and conflating them would make both harder to read.
#
# No ArgoCD Notifications controller here (an earlier version of this script enabled
# and configured it) - the release-outcome feedback loop is now ArgoCD sync hooks
# (PostSync/SyncFail Jobs, committed per-release by open-release-pr.yaml, see
# catalog/lib/argocd-outcome-hook.sh) instead, not a Notifications subscription. See
# docs/multi-cluster.md for why: Notifications fired on ANY completed sync, including
# pure selfHeal drift-correction with zero release involved - confirmed live.
#
# Like hack/bootstrap.sh, this targets an EXISTING cluster context rather than creating
# one - it does not run `kind create cluster`. The first upper cluster this platform
# uses is "kind-prod" (a kind cluster literally named "prod", created ad hoc during
# Phase 3 item 4's design exploration, 2026-08-03 - its NAME is "prod" but the
# environment it currently hosts is "staging", per cicd.yaml's config-driven env->cluster
# mapping; see docs/multi-cluster.md's terminology note). A second upper cluster is just
# a second run of this script against a different context/values.
#
# Idempotent: safe to re-run.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTEXT="${UPPER_CLUSTER_CONTEXT:-kind-prod}"
ARGOCD_CHART_VERSION="10.3.2" # app version v3.5.0 - pinned deliberately, see hack/bootstrap.sh's
                               # own PAC_VERSION/TEKTON_DASHBOARD_VERSION comments for why
                               # ("latest" on a shared cluster is how kind-observe's ArgoCD ended
                               # up with no recorded version anywhere - not repeating that here).

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }
}

require kubectl
require helm

log "0/3 - target the existing ${CONTEXT} cluster (not creating one)"
if ! kubectl config get-contexts -o name | grep -qx "${CONTEXT}"; then
  echo "error: context '${CONTEXT}' not found in your kubeconfig. This script assumes" >&2
  echo "the upper-env cluster already exists - it does not create one. If it's a stopped" >&2
  echo "podman-backed kind cluster, 'podman start <name>-control-plane' first." >&2
  exit 1
fi

log "CNI check (informational, matches kind-observe's own posture - see hack/bootstrap.sh)"
if ! kubectl --context "${CONTEXT}" get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q .; then
  warn "${CONTEXT} runs kindnet, not Calico - same as kind-observe. Deliberately not"
  warn "introducing an inconsistent NetworkPolicy posture between the two clusters without"
  warn "a reason to - see docs/multi-cluster.md."
fi

log "Cross-cluster reachability (informational - verified once live, not re-checked every run)"
echo "  Confirmed 2026-08-10: podman's kind provider puts every kind cluster's node"
echo "  container on one shared 'kind' bridge network by default (unlike Docker Desktop's"
echo "  kind provider, which gives each cluster its own network) - kind-observe and"
echo "  kind-prod's node containers can already reach each other directly by container IP"
echo "  with no extra 'podman network connect' step. See docs/multi-cluster.md for the"
echo "  live verification (container-to-container curl against each other's :6443)."
echo "  A NodePort Service on either cluster is reachable from the other's pods at"
echo "  <node-container-ip>:<nodePort> on this same basis."

log "1/2 - ArgoCD (pinned chart ${ARGOCD_CHART_VERSION})"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
kubectl --context "${CONTEXT}" create namespace argocd --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -
helm upgrade --install argocd argo/argo-cd \
  --kube-context "${CONTEXT}" \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --set dex.enabled=false \
  --wait --timeout 5m

log "app-of-apps root Application"
echo "  Not yet applied by this script - per-tenant gitops repo's clusters/${CONTEXT}/"
echo "  applications/ path needs a one-time root Application pointed at it. See"
echo "  docs/multi-cluster.md's Phase D section; done by hand for the first tenant."

log "Per-app outcome-relay secret (manual, per app onboarded to this cluster)"
echo "  Each app's own namespace on ${CONTEXT} needs a platform-outcome-relay-token"
echo "  Secret before its release-outcome hook Jobs can report anywhere - the SAME"
echo "  value that backs the Secret cluster-registry.relaySecretName points at on the"
echo "  dev cluster. Create it once per app, e.g.:"
echo "    kubectl --context ${CONTEXT} create secret generic platform-outcome-relay-token \\"
echo "      -n <type>-<app-name>-<env> --from-literal=token=<value> \\"
echo "      --dry-run=client -o yaml | kubectl --context ${CONTEXT} apply -f -"
echo "  See docs/multi-cluster.md - never pasted through chat."

log "2/2 - done"
echo "ArgoCD UI: kubectl --context ${CONTEXT} -n argocd port-forward svc/argocd-server 8080:443"
echo "Initial admin password: kubectl --context ${CONTEXT} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
