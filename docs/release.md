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
     (charts/platform-cicd-catalog/templates/tasks/open-release-pr.yaml) - this is where the automated part of the
     flow ends; the flow-root trace closes here (see docs/tracing.md)
  -> 4 independent GitHub Checks run on that PR (sast/image-scan/policy-check/sbom -
     all still stubs, see docs/governance-stubs.md), each individually re-triggerable
  -> branch protection on the gitops repo requires all 4 checks + N human reviewers
  -> once merged, ArgoCD (syncPolicy.automated: prune+selfHeal) syncs the new manifest
     into <type>-<app-name>-staging - the release Pipeline never touches the cluster directly
```

## How the GitHub App's private key stays out of Application namespaces

The GitHub App used for git operations (clone/push/PR-open) is the same App PaC already
uses - but its private key lives in a Secret in the `pipelines-as-code` namespace, which
an Application pipeline pod (running in its own namespace) can't mount directly
(Kubernetes Secrets are namespace-scoped). Rather than copy the key into every
Application's namespace (which would let one compromised Application's Task mint tokens
for every other Application's repos), the shared `token-review-interceptor` service -
already deployed, already TokenReview-authenticated for the CDEvents broker path - has a
second endpoint, `/github-installation-token`, that:

1. Verifies the caller's own Application identity via TokenReview (same mechanism as the
   broker path).
2. Checks the caller's Application namespace actually owns a PaC `Repository` CR that maps
   to the requested `gitops-<app-name>` repo by name - so an Application can only ever get a
   token for its own release repo, never another Application's.
3. Mints a GitHub App installation token scoped to **only that one repo** (via GitHub's
   `repositories` field on the installation-token exchange) and returns it. The
   private key itself never leaves `platform-system`.

`catalog/lib/github-app.sh` wraps this call for `open-release-pr.yaml`.

## Onboarding an Application's release stage (per app)

This is all one-time setup per app, same spirit as onboarding the app repo itself (see
`docs/onboarding.md`) - not something a developer does per release.

1. **Copy the GitHub App credentials** into `platform-system`, once per cluster, not
   per Application (skip if already done):
   ```
   kubectl get secret pipelines-as-code-secret -n pipelines-as-code -o json \
     | jq '{apiVersion, kind, type, data: {"github-application-id": .data["github-application-id"], "github-private-key": .data["github-private-key"]}, metadata: {name: "github-app-creds", namespace: "platform-system"}}' \
     | kubectl apply -f -
   ```

2. **Create the `gitops-<app-name>` repo on GitHub** (e.g. `gitops-nodejs-demo-app`).
   Push `<app-name>/staging/deployment.yaml` + `service.yaml` (adapted from the app's own
   dev manifests), and the four governance-check files from
   `onboarding-templates/.tekton-gitops/` into the new repo's `.tekton/` directory -
   `pull-request-sast.yaml`/`-image-scan.yaml`/`-sbom.yaml` are fully generic as-is;
   `pull-request-policy-check.yaml` needs `<APP_NAMESPACE>`/`<APP_NAME>` substituted:
   ```
   sed -e 's#<APP_NAMESPACE>#app-nodejs-demo-app-cicd#g' -e 's#<APP_NAME>#nodejs-demo-app#g' \
     onboarding-templates/.tekton-gitops/pull-request-policy-check.yaml \
     > <path-to-gitops-repo>/.tekton/pull-request-policy-check.yaml
   ```

3. **Install the PaC GitHub App on the new repo.** While there, check its permissions
   include `Contents: Read & write` and `Pull requests: Read & write` - PaC's own needs
   (webhook delivery, checks) may not already include these, since this App is now also
   doing git operations, not just receiving webhooks.

4. **Apply a PaC `Repository` CR** for the new repo, in the Application's own namespace
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

5. **Apply the ArgoCD template**, with `<APP_NAMESPACE>`, `<APP_NAME>`, `<GITOPS_REPO_URL>`
   substituted:
   ```
   sed -e 's#<APP_NAMESPACE>#app-nodejs-demo-app-cicd#g' -e 's#<APP_NAME>#nodejs-demo-app#g' \
       -e 's#<GITOPS_REPO_URL>#https://github.com/<org>/gitops-nodejs-demo-app#g' \
     charts/platform-cicd-app/templates/argocd/release-application.yaml | kubectl apply -f -
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

## Governance checks, re-triggering, and break-glass

Every gitops-repo release PR carries four independent, required GitHub Checks -
`sast`/`image-scan`/`policy-check`/`sbom` (see the PR body itself, which now documents
this directly - Phase 3 item 8.6). `sast`/`image-scan`/`policy-check` are real as of
Phase 3 items 8.4/8.5/item 2; `sbom` is still a stub pending item 8.7.

**Re-running a failed check**: comment `/retest <check-name>` on the PR (e.g. `/retest
sast`) to re-run just that one, or `/retest` alone to re-run all four - PaC's own native
comment mechanism, no platform code involved. Fix the underlying issue first if the
failure is real; re-running only re-evaluates the check, it does not bypass it.

**Break-glass** (decided with the user, 2026-08-05): who can force a release through a
failing required check, and how it's made visible.

- **Who**: a dedicated GitHub team (e.g. `platform-admins`), not repo/org admins
  generally - narrower, purpose-specific access. This is a **manual GitHub
  configuration step**, not something this platform's code performs: create the team,
  add its intended members, then on the gitops repo's branch protection rule for `main`,
  enable "Allow specified actors to bypass required pull requests" (or the equivalent
  "Do not require approvals/status checks for administrators" toggle, depending on which
  GitHub plan/UI is in use) scoped to that team. Matches this platform's existing
  precedent for branch protection itself (`docs/release.md`'s own "Evolving the approval
  requirement" section above) - a manual, out-of-band GitHub setting, not platform IaC.
- **Audit**: GitHub's own merge/audit-log record is real and already visible on the PR,
  but a security-relevant bypass shouldn't depend on someone thinking to go check it -
  `charts/platform-cicd-catalog/templates/tasks/detect-bypass-merge.yaml` fires on every PR close (via the new
  `.tekton/pull-request-merged.yaml` trigger) and posts a real Slack alert (same
  `slack-webhook-url` Secret/design language as every other notification, but **not**
  gated on `notifications.slack.enabled` - a bypass alert isn't a routine preference)
  whenever a PR merged despite one of the four checks not showing `success`. A normal,
  fully-green merge produces no alert - this is deliberately quiet in the common case.
  Verified live against real GitHub data (not merely the code path): a real merged PR
  with all checks green correctly produced no alert; a real PR with a genuinely failing
  `policy-check`, fed synthetically as `merged=true` (no actual bypass has happened yet
  on this repo), correctly detected it and posted a real, visible Slack message.
  **Not yet verified**: the trigger file's own `on-cel-expression` (`body.action ==
  "closed"`) and `{{ body.pull_request.number }}`/`{{ body.pull_request.merged }}`
  field access - this needs a real PR close event to confirm PaC resolves them exactly
  as written, which wasn't exercised this session (no actual bypass-eligible merge
  occurred). Worth a real end-to-end pass once the `platform-admins` team/branch-
  protection setting above is actually configured.

## Verification

- Push to the app repo, let it flow through build->test->deploy->release for real.
- A PR should appear on `gitops-<app-name>` with the correct image reference, and the
  4 governance checks should show up **independently** in the PR's checks list (each
  individually re-runnable, e.g. via `/retest sast` PR comment).
- Security check: confirm `/github-installation-token` genuinely rejects a request for
  a repo the caller's Application doesn't own (test from `platform-cicd-demo`'s SA
  requesting a different, unrelated `gitops-*` repo name - should get a 403).
- After merge: `kubectl get application nodejs-demo-app-staging -n argocd` shows
  `Synced`/`Healthy`, and the running pod in `platform-cicd-demo-staging` is on the new
  image - confirmed via `kubectl get pods -n platform-cicd-demo-staging -o
  jsonpath='{.items[0].spec.containers[0].image}'` - with no direct `kubectl` from any
  Tekton Task in that path.
