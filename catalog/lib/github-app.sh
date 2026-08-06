#!/usr/bin/env bash
# catalog/lib/github-app.sh
#
# Fetches a short-lived, single-repo-scoped GitHub App installation token from the
# shared broker's /github-installation-token endpoint (see
# platform/broker/cmd/token-review-interceptor/github_app.go and docs/release.md). The
# App's private key never leaves the platform-system namespace - this call proves the
# caller's own Application identity (same audience-bound projected ServiceAccount token
# pattern as cdevents.sh) and gets back only a token scoped to the one repo it asked
# for and was authorized for, never the key itself.
#
# Auth: the caller's own audience-bound projected ServiceAccount token, same pattern as
# cdevents.sh - there is no platform-minted credential anywhere in this path either.

set -euo pipefail

: "${GITHUB_TOKEN_BROKER_URL:?GITHUB_TOKEN_BROKER_URL must be set (in-cluster shared interceptor address)}"

_GITHUB_TOKEN_BROKER_TOKEN_PATH="/var/run/secrets/platform/github-token-broker-token"

# github_app_installation_token <owner> <repo>
# Prints the installation token (and nothing else) on stdout. Fails loudly (via
# --fail) if the caller's Application namespace doesn't own a Repository CR that maps to
# <repo> under the gitops-<app-name> convention, or if the App isn't installed on that
# repo yet - both are real setup states, not transient errors, so this deliberately
# does not retry the way cdevent_send does for its at-least-once delivery model.
github_app_installation_token() {
  local owner="$1" repo="$2"

  local sa_token
  sa_token="$(cat "${_GITHUB_TOKEN_BROKER_TOKEN_PATH}")"

  local response
  response="$(curl --fail --silent --show-error --max-time 15 \
    -X POST "${GITHUB_TOKEN_BROKER_URL}" \
    -H "Authorization: Bearer ${sa_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg owner "${owner}" --arg repo "${repo}" '{owner: $owner, repo: $repo}')")"

  jq -er '.token' <<<"${response}"
}
