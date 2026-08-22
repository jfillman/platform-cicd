#!/usr/bin/env bash
# catalog/lib/github-app.sh
#
# Fetches a short-lived, single-repo-scoped GitHub App installation token from the
# shared broker's /github-installation-token endpoint (see
# platform/broker/cmd/token-review-interceptor and docs/admin/release.md). The App's
# private key never leaves platform-system - this call proves the caller's own
# Application identity (same TokenReview pattern as cdevents.sh) and gets back only a
# token scoped to the one repo it asked for, never the key itself.

set -euo pipefail

: "${GITHUB_TOKEN_BROKER_URL:?GITHUB_TOKEN_BROKER_URL must be set (in-cluster shared interceptor address)}"

_GITHUB_TOKEN_BROKER_TOKEN_PATH="/var/run/secrets/platform/github-token-broker-token"

# github_app_installation_token <owner> <repo>
# Prints the installation token (and nothing else) on stdout. Fails loudly if the
# caller's Application namespace doesn't own a Repository CR mapping to <repo>, or if
# the App isn't installed there - real setup states, not transient errors, so this
# deliberately doesn't retry like cdevent_send does.
github_app_installation_token() {
  local owner="$1" repo="$2"

  local sa_token
  sa_token="$(cat "${_GITHUB_TOKEN_BROKER_TOKEN_PATH}")"

  # No --fail here (deliberately): curl --fail discards the response body on a non-2xx,
  # which was swallowing the broker's own diagnostic message (e.g. "GitHub installation
  # lookup for owner/repo: status 404") behind a generic jq parse error - the actual
  # failure a private gitops repo hits when the GitHub App hasn't been installed on it
  # yet (see docs/admin/release.md step 3) looked like an unrelated JSON bug instead of
  # a clear "go install the App there" pointer.
  local raw http_code body
  raw="$(curl --silent --show-error --max-time 15 -w '\n%{http_code}' \
    -X POST "${GITHUB_TOKEN_BROKER_URL}" \
    -H "Authorization: Bearer ${sa_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg owner "${owner}" --arg repo "${repo}" '{owner: $owner, repo: $repo}')")"
  http_code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  if [[ "${http_code}" != "200" ]]; then
    echo "github-installation-token request for ${owner}/${repo} failed: HTTP ${http_code}: ${body}" >&2
    echo "If ${repo} is private, confirm the platform's GitHub App is installed on it (Settings > GitHub Apps on the repo/org) with Contents: Read & write and Pull requests: Read & write - see docs/admin/release.md step 3. A repo the App can't see returns a 404 here." >&2
    exit 1
  fi

  jq -er '.token' <<<"${body}"
}
