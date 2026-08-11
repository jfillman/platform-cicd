#!/usr/bin/env bash
# catalog/lib/argocd-outcome-hook.sh
#
# Runs as an ArgoCD PostSync/SyncFail hook Job on a cluster-mapped upper-env cluster
# (see open-release-pr.yaml's platform-outcome-postsync.yaml/platform-outcome-syncfail.yaml,
# docs/multi-cluster.md) - reports a confirmed release outcome straight to the dev
# cluster's argocd-outcome-relay. Replaces an earlier ArgoCD-Notifications-based design
# entirely - see docs/multi-cluster.md for why: Notifications fired on ANY completed
# sync operation (including pure selfHeal drift-correction with no release involved -
# confirmed live), and reading per-release data off the Application object's own
# metadata was racy against the app-of-apps root's independent reconcile loop (also
# confirmed live). Neither problem exists here: a hook Job only runs when the
# resources in ITS OWN sync actually had something to (re)apply, and PostSync
# specifically only fires once those resources are deployed AND healthy (confirmed
# live - see docs/multi-cluster.md's hook-timing test) - so there's no live object to
# read at all, only env vars baked in by open-release-pr.yaml at commit time, at the
# exact moment it already had the real values in hand.
#
# PHASE is the one field baked in per-hook-type (Succeeded for the PostSync variant,
# Failed for the SyncFail one) rather than discovered live - which hook ran already
# tells us the outcome.
set -euo pipefail

: "${RELAY_URL:?RELAY_URL must be set}"
: "${APP_NAMESPACE:?APP_NAMESPACE must be set}"
: "${APP_NAME:?APP_NAME must be set}"
: "${ENV:?ENV must be set}"
: "${PHASE:?PHASE must be set}"
: "${POD_NAMESPACE:?POD_NAMESPACE must be set - downward API, set on the hook Job spec}"

# The shared per-cluster secret, hand-provisioned once per app namespace on THIS
# cluster (never committed to git, never passed through open-release-pr.yaml - that
# Task runs on the dev cluster and never sees this value) - see docs/multi-cluster.md
# for the exact provisioning command.
token="$(kubectl get secret platform-outcome-relay-token -n "${POD_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# jq -n --arg, not string interpolation - every field here is safely JSON-encoded
# regardless of content, the same lesson this platform's own bash-to-JSON call sites
# (cdevents.sh, open-release-pr.yaml's own PR body) already learned the hard way.
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
  --arg configJsonB64 "${CONFIG_JSON_B64:-}" \
  '{appNamespace: $appNamespace, appName: $appName, env: $env, phase: $phase, revision: $revision, gitUrl: $gitUrl, gitRevision: $gitRevision, flowStartTime: $flowStartTime, finishedAt: $finishedAt, configJsonB64: $configJsonB64}')"

echo "[argocd-outcome-hook] app=${APP_NAME} env=${ENV} phase=${PHASE}: reporting to ${RELAY_URL}"
curl --fail --silent --show-error --max-time 15 \
  -X POST "${RELAY_URL}" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "${payload}"
echo
