#!/usr/bin/env bash
# hack/promote-catalog.sh
#
# The cluster-touching half of catalog versioning (see docs/admin/catalog-versioning.md)
# - runs locally, not CI, since kind-observe has no public endpoint for GitHub-hosted
# runners to reach. CI covers lint/render checks on every PR; this answers "does a real
# pipeline still work", via a second install of the same chart into a second namespace.
#
# Usage:
#   hack/promote-catalog.sh canary   - install/upgrade the canary release only
#   hack/promote-catalog.sh promote  - install/upgrade the real production release
#
# Canary testing itself (pointing a dedicated Application's catalogNamespace at
# platform-catalog-canary and running a real build->test->deploy) is a manual step -
# this script only handles the two Helm operations.

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
