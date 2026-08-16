#!/usr/bin/env bash
# hack/bootstrap.sh
#
# Targets the existing shared `kind-observe` dev cluster by default rather than creating
# a dedicated one - see docs/bootstrap.md "Why kind-observe, not a fresh cluster" for the
# full reasoning and the tradeoffs that decision carries (most importantly: no
# NetworkPolicy enforcement, see the CNI note below). This script only installs what's
# genuinely missing on that cluster and is careful not to touch anything already owned
# by other workloads there (holmesgpt, order-processing-service, payment-service, the
# existing observability/argocd/crossplane-system stacks).
#
# Idempotent: safe to re-run. Each step checks whether it's already done before acting.
#
# Retargetable via env vars (2026-08-15, standing up a second, independent instance of
# this control plane on kind-dev for idp - see idp/docs/service-catalog-design.md §0's
# NodeJSApplication CicdOnboarding note): defaults below reproduce today's kind-observe
# behavior exactly, so a plain `./hack/bootstrap.sh` is unchanged. Override for another
# cluster, e.g. `CONTEXT=kind-dev KIND_CLUSTER_NAME=dev ./hack/bootstrap.sh` - VALUES_FILE
# no longer needs to be passed explicitly for a cluster that already has one (see
# auto-discovery below); still overridable by hand for a one-off run. The chart-level
# per-cluster values (Fulcio CA/root cert, tenantsRepoUrl) live in VALUES_FILE, not here -
# see charts/platform-cicd-control-plane/values.yaml's own fulcio/tenantsRepoUrl comments
# for why those specifically can't just be hardcoded per-cluster in the templates
# themselves.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTEXT="${CONTEXT:-kind-observe}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-observe}" # kind's own name for the cluster, i.e. context minus the "kind-" prefix
CATALOG_IMAGE_TAG="${CATALOG_IMAGE_TAG:-latest}"
VALUES_FILE="${VALUES_FILE:-}" # optional -f override for both helm upgrade --install calls below

# Auto-discovery (2026-08-16, feedback_cluster_agnostic_idp memory): a per-cluster
# values file at the conventional path hack/values-<context>.yaml (e.g.
# hack/values-kind-observe.yaml, hack/values-kind-dev.yaml - see
# hack/generate-cluster-values.sh for how a NEW cluster's file gets created) is picked
# up automatically with zero flag needed, instead of requiring every invocation to
# remember to pass VALUES_FILE by hand. An explicit VALUES_FILE always wins.
if [[ -z "${VALUES_FILE}" && -f "hack/values-${CONTEXT}.yaml" ]]; then
  VALUES_FILE="hack/values-${CONTEXT}.yaml"
fi

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }
}

require kubectl
require helm
require docker

log "0/6 - target the existing ${CONTEXT} cluster (not creating a new one)"
if ! kubectl config get-contexts -o name | grep -qx "${CONTEXT}"; then
  echo "error: context '${CONTEXT}' not found in your kubeconfig. This script assumes" >&2
  echo "you already have that cluster running - it does not create one." >&2
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
# across every Application's namespace, which cuts against the "no elevated identity
# anywhere" posture the rest of this platform holds to (see
# charts/platform-cicd-app/templates/identity/pipeline-runner.yaml's
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

log "1.5/6 - Tekton Chains (not present on kind-observe) - keyless image/provenance signing, see docs/image-signing.md"
# Chains ships one Deployment (tekton-chains-controller) - no separate webhook Deployment
# like Pipelines/Triggers/PaC have (confirmed live from the release manifest, not assumed
# from that pattern).
kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml
kubectl -n tekton-chains rollout status deployment/tekton-chains-controller --timeout=180s

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

log "3/6 - platform catalog (Tasks/Pipelines/StepActions, read-only for Applications)"
# Phase 3 item 7: was bare `kubectl apply -n platform-catalog -f catalog/...` - now a
# real Helm release, giving this the same version/rollback story as everything else this
# platform owns (see docs/catalog-versioning.md). Chart version bumps happen in
# charts/platform-cicd-catalog/Chart.yaml deliberately, not via --version here, so a
# `git log` on that one line is the release history.
kubectl create namespace platform-catalog --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install platform-cicd-catalog charts/platform-cicd-catalog \
  --namespace platform-catalog --wait

log "4/6 - build + publish toolbox, dora-exporter, token-review-interceptor, argocd-outcome-relay"
# The toolbox image is `docker push`ed to a real registry (ghcr.io/jfillman, the same
# public GHCR namespace nodejs-demo-app's own image already pulls from with zero
# imagePullSecrets configured anywhere - confirmed live) rather than `kind load`ed. This
# is a real bug fix, not a style choice: a kind-loaded/`ctr images import`ed image has no
# registry-qualified name, so every Tekton step's containerStatus.imageID for it comes
# back as a bare `sha256:<digest>` (confirmed live via `kubectl get taskrun ... -o json |
# jq '.status.steps[].imageID'`) instead of `repo@sha256:<digest>`. Tekton Chains'
# PipelineRun-level SLSA materials-gathering walks every constituent TaskRun's step
# imageIDs, and chokes hard on the bare one ("expected imageID sha256:... to be separable
# by @"), breaking signing for the ENTIRE PipelineRun - not just skipping that one
# material. Since the toolbox image is used by nearly every step in every pipeline, this
# broke Chains signing for every real build. Reproduced identically across two
# independent real builds before finding the root cause - see
# platform/sigstore/chains-config-patch.yaml's artifacts.taskrun.storage comment for the
# full incident note.
docker build -f catalog/toolbox/Dockerfile -t "ghcr.io/jfillman/platform-cicd-toolbox:${CATALOG_IMAGE_TAG}" .
docker push "ghcr.io/jfillman/platform-cicd-toolbox:${CATALOG_IMAGE_TAG}"
# Real gap found+fixed 2026-08-15: this build+push step never existed before - DORA
# exporter only ever ran on kind-observe because it was kind-loaded by hand once,
# off-script (see charts/platform-cicd-control-plane/templates/dora-exporter/
# deployment.yaml's own comment). Registry-published like toolbox above - it's not a
# Tekton step image, so none of the Chains materials-gathering imageID bug applies, and a
# real registry means no per-cluster kind-load step going forward.
docker build -f platform/dora-exporter/cmd/dora-exporter/Dockerfile \
  -t "ghcr.io/jfillman/platform-cicd-dora-exporter:${CATALOG_IMAGE_TAG}" platform/dora-exporter
docker push "ghcr.io/jfillman/platform-cicd-dora-exporter:${CATALOG_IMAGE_TAG}"
# Real bugs found+fixed 2026-08-16 (cluster-agnostic declarative install work, idp): both
# of these referenced ghcr.io/platform-cicd/... - an org that doesn't exist (confirmed
# live via `docker pull` -> "manifest unknown" and `gh api orgs/platform-cicd` -> 404),
# so neither was ever really publishable under that name. token-review-interceptor was
# `kind load`-ed as a workaround (fine on a cluster kind-load actually reaches, but not
# reproducible/declarative); argocd-outcome-relay had NO build/load step anywhere at all
# - kind-observe's long-running relay pods were surviving purely on a stale image cached
# from some past off-script load, same class of gap dora-exporter had. Both now real,
# registry-published images under the same ghcr.io/jfillman namespace as everything else.
# Neither is a Tekton step image, so the imageID/Chains bug above doesn't apply to either.
docker build -f platform/broker/cmd/token-review-interceptor/Dockerfile \
  -t "ghcr.io/jfillman/platform-cicd-token-review-interceptor:${CATALOG_IMAGE_TAG}" platform/broker
docker push "ghcr.io/jfillman/platform-cicd-token-review-interceptor:${CATALOG_IMAGE_TAG}"
docker build -f platform/broker/cmd/argocd-outcome-relay/Dockerfile \
  -t "ghcr.io/jfillman/platform-cicd-argocd-outcome-relay:${CATALOG_IMAGE_TAG}" platform/broker
docker push "ghcr.io/jfillman/platform-cicd-argocd-outcome-relay:${CATALOG_IMAGE_TAG}"

log "5/6 - control plane (broker, DORA exporter, detectors, Fulcio, ClusterSecretStore)"
# Phase 3 item 7: consolidates what used to be several separately hand-`kubectl apply`'d
# files (platform/broker/manifests/{interceptor,eventlistener,stalled-pipeline-detector-
# cronjob}.yaml, platform/argocd/pr-namespace-ttl-sweep-cronjob.yaml, platform/
# dora-exporter/manifests/*, platform/sigstore/*) into one real Helm release - several of
# these (DORA exporter, Fulcio, the Chains config patch) had never actually been added
# back into this idempotent bootstrap flow after being applied once by hand during their
# own build sessions, a real gap this closes, not just a refactor. Fulcio's root CA
# secret is still a one-time manual bootstrap step - see docs/image-signing.md - this
# does not create it, only consumes it.
#
# NOT a `kubectl create namespace platform-system` here (real bug found live 2026-08-15,
# first true from-scratch install of this chart, on kind-dev): templates/broker/
# interceptor.yaml already declares its own `kind: Namespace, name: platform-system` -
# pre-creating it via plain kubectl first means Helm can't import it into the release
# ("exists and cannot be imported... missing key app.kubernetes.io/managed-by") on this
# Helm version (confirmed live, v3.21.3). kind-observe's platform-system happens to
# already be cleanly Helm-owned (confirmed live) - this redundant line never mattered
# there, just never helped either. Let the chart create it.
HELM_VALUES_ARGS=()
if [[ -n "${VALUES_FILE}" ]]; then
  HELM_VALUES_ARGS=(-f "${VALUES_FILE}")
fi
helm upgrade --install platform-cicd-control-plane charts/platform-cicd-control-plane \
  --namespace platform-system --create-namespace --wait "${HELM_VALUES_ARGS[@]}"

log "6/6 - Grafana dashboards, provisioned into the existing Grafana in observability ns"
kubectl apply -k observability/grafana/

log "Done. Next: onboard a pilot repo - see docs/onboarding.md."
echo "Grafana: kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "         (existing admin creds: kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
