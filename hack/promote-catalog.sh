#!/usr/bin/env bash
# hack/promote-catalog.sh
#
# The real, cluster-touching half of catalog versioning/testing (see
# docs/catalog-versioning.md) - runs locally, not in CI, because kind-observe has no
# public endpoint GitHub-hosted runners can reach (see .github/workflows/
# catalog-ci.yaml's own header comment). CI covers lint/render/structural checks on
# every PR; this script covers the "does a real pipeline still work" question CI can't
# answer, using a second install of the SAME chart into a second namespace rather than
# any OCI-bundle machinery - see docs/catalog-versioning.md's Option A/B discussion for
# why this is deliberately the simple path for now.
#
# Usage:
#   hack/promote-catalog.sh canary   - install/upgrade the canary release only
#   hack/promote-catalog.sh promote  - install/upgrade the real production release
#
# Canary testing itself (pointing one dedicated Application's platformIdentity.catalogNamespace
# at platform-catalog-canary and running a real build->test->deploy) is a manual step -
# this script only handles the two Helm operations, not picking/running a canary Application.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTEXT="kind-observe"
CHART="charts/platform-cicd-catalog"

usage() {
  echo "usage: $0 {canary|promote}" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
kubectl config use-context "${CONTEXT}" >/dev/null

case "$1" in
  canary)
    echo "==> Installing/upgrading canary release into platform-catalog-canary"
    kubectl create namespace platform-catalog-canary --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install platform-cicd-catalog-canary "${CHART}" \
      --namespace platform-catalog-canary --wait
    echo "==> Done. Point one dedicated canary Application's platformIdentity.catalogNamespace"
    echo "    at platform-catalog-canary and run a real build->test->deploy before promoting."
    ;;
  promote)
    read -r -p "Promote the currently-canaried chart version to REAL production (platform-catalog)? [y/N] " confirm
    [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Aborted."; exit 1; }
    echo "==> Installing/upgrading production release into platform-catalog"
    helm upgrade --install platform-cicd-catalog "${CHART}" \
      --namespace platform-catalog --wait
    echo "==> Done. Every Application pointed at platform-catalog (the default) now sees this"
    echo "    version. Roll back with: helm rollback platform-cicd-catalog -n platform-catalog"
    ;;
  *)
    usage
    ;;
esac
