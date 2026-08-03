# Release stage: GitOps PR promotion to staging

The release stage promotes the exact image that already passed test/deploy-to-dev
(never rebuilt) to a `staging` environment, via a pull request against a dedicated
GitOps repo - gated by governance checks reported as independent GitHub Checks and a
required-reviewer branch-protection rule. This is modeled directly on a real prior
production pattern (`gitops-main/charts/cd-pipelines`/`cd-pipelines-user`, analyzed live
against its actual Tekton YAML and a real merged PR), adapted to this platform's
Pipelines-as-Code/ArgoCD stack - see the "Release Stage" section of the architecture
plan for the full comparison of what was ported vs. deliberately left behind.

## Flow

```
deploy (dev) succeeds
  -> dev.cdevents.service.deployed CDEvent, now carrying git-url/revision forward
  -> broker fires `release` PipelineRun
  -> release opens a PR against gitops-<app-name>, bumping the staging image tag
     (catalog/tasks/open-release-pr.yaml) - this is where the automated part of the
     flow ends; the flow-root trace closes here (see docs/tracing.md)
  -> 4 independent GitHub Checks run on that PR (sast/image-scan/policy-check/sbom -
     all still stubs, see docs/governance-stubs.md), each individually re-triggerable
  -> branch protection on the gitops repo requires all 4 checks + N human reviewers
  -> once merged, ArgoCD (syncPolicy.automated: prune+selfHeal) syncs the new manifest
     into <tenant>-staging - the release Pipeline never touches the cluster directly
```

## How the GitHub App's private key stays out of tenant namespaces

The GitHub App used for git operations (clone/push/PR-open) is the same App PaC already
uses - but its private key lives in a Secret in the `pipelines-as-code` namespace, which
a tenant pipeline pod (running in its own tenant namespace) can't mount directly
(Kubernetes Secrets are namespace-scoped). Rather than copy the key into every tenant
namespace (which would let one compromised tenant Task mint tokens for every other
tenant's repos), the shared `token-review-interceptor` service - already deployed,
already TokenReview-authenticated for the CDEvents broker path - has a second endpoint,
`/github-installation-token`, that:

1. Verifies the caller's own tenant identity via TokenReview (same mechanism as the
   broker path).
2. Checks the caller's tenant namespace actually owns a PaC `Repository` CR that maps
   to the requested `gitops-<app-name>` repo by name - so a tenant can only ever get a
   token for its own release repo, never another tenant's.
3. Mints a GitHub App installation token scoped to **only that one repo** (via GitHub's
   `repositories` field on the installation-token exchange) and returns it. The
   private key itself never leaves `platform-system`.

`catalog/lib/github-app.sh` wraps this call for `open-release-pr.yaml`.

## Onboarding a tenant's release stage (per app)

This is all one-time setup per app, same spirit as onboarding the app repo itself (see
`docs/onboarding.md`) - not something a developer does per release.

1. **Copy the GitHub App credentials** into `platform-system`, once per cluster, not
   per tenant (skip if already done):
   ```
   kubectl get secret pipelines-as-code-secret -n pipelines-as-code -o json \
     | jq '{apiVersion, kind, type, data: {"github-application-id": .data["github-application-id"], "github-private-key": .data["github-private-key"]}, metadata: {name: "github-app-creds", namespace: "platform-system"}}' \
     | kubectl apply -f -
   ```

2. **Create the `gitops-<app-name>` repo on GitHub** (e.g. `gitops-nodejs-demo-app`).
   Push the scaffolded content provided alongside this doc: `<app-name>/staging/deployment.yaml`
   + `service.yaml`, and the four `.tekton/pull-request-*.yaml` governance-check files.

3. **Install the PaC GitHub App on the new repo.** While there, check its permissions
   include `Contents: Read & write` and `Pull requests: Read & write` - PaC's own needs
   (webhook delivery, checks) may not already include these, since this App is now also
   doing git operations, not just receiving webhooks.

4. **Apply a PaC `Repository` CR** for the new repo, in the tenant's own namespace
   (same pattern as the app repo's own Repository CR):
   ```
   kubectl apply -f - <<EOF
   apiVersion: pipelinesascode.tekton.dev/v1alpha1
   kind: Repository
   metadata:
     name: gitops-nodejs-demo-app
     namespace: platform-cicd-demo
   spec:
     url: https://github.com/<org>/gitops-nodejs-demo-app
   EOF
   ```

5. **Apply the ArgoCD template**, with `<TENANT>`, `<APP_NAME>`, `<GITOPS_REPO_URL>`
   substituted:
   ```
   sed -e 's#<TENANT>#platform-cicd-demo#g' -e 's#<APP_NAME>#nodejs-demo-app#g' \
       -e 's#<GITOPS_REPO_URL>#https://github.com/<org>/gitops-nodejs-demo-app#g' \
     platform/argocd/tenant-release-argocd-template.yaml | kubectl apply -f -
   ```

6. **Configure branch protection** on the gitops repo's `main` branch (GitHub UI or
   API - not IaC-managed by this platform, same as the old system, just actually
   documented this time): require status checks `sast`, `image-scan`, `policy-check`,
   `sbom` to pass, and require **2 approving reviews**. Enable "Allow auto-merge" on
   the repo so a PR merges itself the moment checks + reviews are satisfied, without
   needing anyone to click Merge.

## Evolving the approval requirement

The required-reviewer count is a branch protection setting, not platform code - once
the governance checks are real (Phase 3) and trusted, drop
`required_pull_request_reviews.required_approving_review_count` to `0` on the gitops
repo directly. Nothing in the platform needs to change for this; the PR flow becomes
fully automatic (checks-gated only) the moment that setting changes.

## Verification

- Push to the app repo, let it flow through build->test->deploy->release for real.
- A PR should appear on `gitops-<app-name>` with the correct image reference, and the
  4 governance checks should show up **independently** in the PR's checks list (each
  individually re-runnable, e.g. via `/retest sast` PR comment).
- Security check: confirm `/github-installation-token` genuinely rejects a request for
  a repo the caller's tenant doesn't own (test from `platform-cicd-demo`'s SA
  requesting a different, unrelated `gitops-*` repo name - should get a 403).
- After merge: `kubectl get application nodejs-demo-app-staging -n argocd` shows
  `Synced`/`Healthy`, and the running pod in `platform-cicd-demo-staging` is on the new
  image - confirmed via `kubectl get pods -n platform-cicd-demo-staging -o
  jsonpath='{.items[0].spec.containers[0].image}'` - with no direct `kubectl` from any
  Tekton Task in that path.
