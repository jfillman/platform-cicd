#!/usr/bin/env bash
# catalog/lib/argocd-outcome-hook.sh
#
# Runs as an ArgoCD PostSync/SyncFail hook Job on a cluster-mapped upper-env cluster -
# reports a confirmed release outcome straight to the dev cluster's
# argocd-outcome-relay. Replaces an earlier ArgoCD-Notifications design: Notifications
# fired on any completed sync (including pure selfHeal drift, no release involved), and
# reading per-release data off the Application object's own metadata was racy against
# the app-of-apps root's independent reconcile loop. A hook Job avoids both - it only
# runs when its own sync had something to apply, PostSync only fires once healthy, and
# every value here is an env var baked in by open-release-pr.yaml at commit time
# instead of read live. See docs/admin/multi-cluster.md.
#
# PHASE is baked in per-hook-type (Succeeded/Failed) rather than discovered live -
# which hook ran already tells us the outcome.
set -euo pipefail

: "${RELAY_URL:?RELAY_URL must be set}"
: "${APP_NAMESPACE:?APP_NAMESPACE must be set}"
: "${APP_NAME:?APP_NAME must be set}"
: "${ENV:?ENV must be set}"
: "${PHASE:?PHASE must be set}"
: "${POD_NAMESPACE:?POD_NAMESPACE must be set - downward API, set on the hook Job spec}"

# CHAIN_ID and PR_CREATED_AT are optional, unlike the required fields above: both feed
# release-outcome-span.yaml's Tempo correlation (chain-id tagging, PR-creation as the
# real start anchor, falling back to flow-start-time if empty), and making them
# required would break every release from an app onboarded before either field existed.

# Shared per-cluster secret, hand-provisioned once per app namespace on THIS cluster -
# never committed to git, never passed through open-release-pr.yaml (which runs on the
# dev cluster and never sees it). See docs/admin/multi-cluster.md for provisioning.
token="$(kubectl get secret platform-outcome-relay-token -n "${POD_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# jq -n --arg, not string interpolation, so every field is safely JSON-encoded
# regardless of content (same convention as cdevents.sh).
payload="$(jq -n \
  --arg appNamespace "${APP_NAMESPACE}" \
  --arg appName "${APP_NAME}" \
  --arg env "${ENV}" \
  --arg phase "${PHASE}" \
  --arg revision "${GITOPS_REVISION:-}" \
  --arg gitUrl "${GIT_URL:-}" \
  --arg gitRevision "${GIT_REVISION:-}" \
  --arg flowStartTime "${FLOW_START_TIME:-}" \
  --arg finishedAt "${finished_at}" \
  --arg prUrl "${PR_URL:-}" \
  --arg configJsonB64 "${CONFIG_JSON_B64:-}" \
  --arg chainId "${CHAIN_ID:-}" \
  --arg prCreatedAt "${PR_CREATED_AT:-}" \
  '{appNamespace: $appNamespace, appName: $appName, env: $env, phase: $phase, revision: $revision, gitUrl: $gitUrl, gitRevision: $gitRevision, flowStartTime: $flowStartTime, finishedAt: $finishedAt, prUrl: $prUrl, configJsonB64: $configJsonB64, chainId: $chainId, prCreatedAt: $prCreatedAt}')"

echo "[argocd-outcome-hook] app=${APP_NAME} env=${ENV} phase=${PHASE}: reporting to ${RELAY_URL}"
curl --fail --silent --show-error --max-time 15 \
  -X POST "${RELAY_URL}" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "${payload}"
echo
