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

     `policy-check` verifies a `gitsign` signature on the actual APP-repo commit that
     triggered this release (see docs/commit-signing.md) - not this gitops PR's own
     commits, which are machine-generated and never signed. **This means the app-repo
     commit that ends up promoted must itself be gitsign-signed, which a GitHub PR
     merge-button click always breaks** (merge/squash/rebase all produce a new,
     unsigned commit object) - see docs/commit-signing.md's "Merge strategy matters"
     section before assuming "review the app PR, click Merge" will work end to end.
  -> once merged, ArgoCD (syncPolicy.automated: prune+selfHeal) syncs the new manifest
     into <type>-<app-name>-staging - the release Pipeline never touches the cluster directly
```

## Performance: no clone, no schema re-validation, for the common (event-chained) case

Neither `deploy.yaml` (deploys via `kubectl set image`) nor `release.yaml`
(`open-release-pr.yaml` does its own separate clone of the *gitops* repo, a different
repo entirely) ever reads from the app repo's own source tree. Both used to
unconditionally clone it and run full JSON-schema validation on `cicd.yaml` anyway,
purely so `notify-slack`'s finally step could read two fields off it - a full clone plus
a dynamically-provisioned PVC, on every single stage transition, for a workspace that
was otherwise dead weight.

Fixed: `cicd.yaml`'s already-validated content is now forwarded stage-to-stage through
the CDEvents chain instead (`customData.platform.config_json` - see docs/chaining.md),
ultimately sourced from `test`'s own `validate-config` (which always runs regardless,
needed for `resolve-agent-image`/`integration-test`). `deploy.yaml`/`release.yaml`'s
`source` workspace is `optional: true`, and `flow-triggers.yaml` skips binding it
entirely for the common event-chained case, which is what actually avoids the PVC
provisioning cost, not just a clone. `catalog/tasks/resolve-notify-config.yaml` is the
arbiter: pass through the inherited value, or (only for a git-rooted deploy/release,
where a real workspace is bound) clone and read `cicd.yaml` directly off it - there's no
separate `clone-repo` task any more. That last point isn't a style choice: Tekton
rejects a Pipeline at *admission* time if any task references an optional Pipeline
workspace through its own *required* Task-level workspace, regardless of `when`-gating -
confirmed live the hard way (the shared, hub-resolved `git-clone` catalog Task declares
its workspace required, so it can never coexist with an optional Pipeline workspace, no
matter how it's gated). See `resolve-notify-config.yaml`'s own header for the full story.

**Tradeoff, deliberate**: that git-rooted fallback read is *not* schema-validated the way
`validate-config` does it - `deploy.yaml`/`release.yaml` dropped `validate-config`
entirely, since nothing else in either pipeline ever consumed its output. This relies on
`cicd.yaml` having already been schema-validated earlier in the app's lifecycle
(`onboarding-resync` validates it when generating the `.tekton/` files in the first
place, and `build` validates it again for any flow that includes a `build` step) - a
malformed `cicd.yaml` reaching a git-rooted `deploy`/`release` with no earlier validation
in its own history is a real, if narrow, gap. Revisit if that ever proves to matter in
practice (every real git-rooted deploy/release use case today is tag-triggered - see
`resolve-image-ref.yaml`'s own header).

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

2. **Create the `gitops-<app-name>` repo on GitHub** (e.g. `gitops-nodejs-demo-app`) and
   push `<app-name>/staging/deployment.yaml` + `service.yaml` (adapted from the app's own
   dev manifests) to it - this is the one part of the gitops repo's content the platform
   has no way to generate for you (it doesn't know your Deployment's shape).

   The four governance-check `.tekton/` files (`pull-request-sast.yaml`/`-image-scan.yaml`/
   `-sbom.yaml`/`-policy-check.yaml`, with `<APP_NAMESPACE>`/`<APP_NAME>` already
   substituted) do **not** need to be hand-copied - `deliver-onboarding-files.yaml`'s
   `deliver-gitops-repo-files` step delivers them via the same onboarding-resync PR
   mechanism that delivers the app repo's own `.tekton/` files (see
   [onboarding.md](onboarding.md) step 6), as long as `platformIdentity.gitopsRepoUrl` was
   given at install time and the `Repository` CR from step 4 below already exists. Confirmed
   live: a fresh gitops repo with nothing but the two manifests above gets all four
   governance files opened as a PR automatically on the next onboarding-resync run.

3. **Install the PaC GitHub App on the new repo.** While there, check its permissions
   include `Contents: Read & write` and `Pull requests: Read & write` - PaC's own needs
   (webhook delivery, checks) may not already include these, since this App is now also
   doing git operations, not just receiving webhooks.

4. **Nothing to do here anymore** - as long as `platformIdentity.gitopsRepoUrl` is set,
   `charts/platform-cicd-app/templates/pipelines-as-code/repository.yaml` renders the
   `gitops-<app-name>` PaC `Repository` CR automatically (same file that renders the app
   repo's own Repository CR - see [onboarding.md](onboarding.md) step 1). Previously a
   manual `kubectl apply`, folded into the chart once step 2 above already needs
   `gitopsRepoUrl` to be set at install time regardless.

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

**Each check also posts its own real PR comment** on top of the GitHub Check PaC already
reports natively (`catalog/tasks/comment-pr-check-result.yaml`, 2026-08-10) - failure
detail (a live pod-log excerpt), a gate-specific recommendation, and the exact `/retest
<gate>` command on failure; a short confirmation on success. It edits its own prior
comment on a gate in place (a hidden `<!-- platform-cicd:gate:<name> -->` marker) rather
than always appending, so re-verifying an unchanged commit updates the existing comment
instead of spamming a duplicate. **Real race, found live 2026-08-12**: for a cluster-mapped release,
`open-release-pr.yaml` opens a release PR with two commits (the promote commit, then a
second outcome-hooks commit pushed right after - see [multi-cluster.md](multi-cluster.md)),
and since every commit gets independently re-verified, two check runs for the *same* gate can land close
enough together that both read "no existing comment" before either posts - two comments,
not deduped. Fixed without a lock: after posting, re-list this gate's own comments and
collapse to the single earliest (lowest id) survivor - every racing run computes the
same decision off the same eventually-consistent list, so they converge regardless of
which one "wins" (a second run's delete of an already-deleted duplicate is expected and
tolerated).

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
  **Still not fully verified** (a real PR close event with an actual bypass hasn't been
  exercised), but a real, related bug WAS found and fixed live 2026-08-12 while
  investigating something else: PaC evaluates a Pipeline's `on-cel-expression` against
  *every* webhook delivery for the repo once one is present, not just events shaped like
  what the expression expects - confirmed live via a genuine push webhook (a release
  PR's own merge fires one, alongside the `pull_request` event) throwing a real CEL "no
  such key: action" error against this file's bare `body.action == "closed"`, reported
  back as a false-alarm bot comment ("errors in your PipelineRun template") on the very
  PR that had just successfully merged. Fixed with `has(body.action) && body.action ==
  "closed"` - `has()` short-circuits the rest of the expression when the event isn't
  PR-shaped, same fix applied to all four governance-check files below (they had the
  identical bare-field pattern on `body.pull_request.*`). Doesn't confirm the intended
  bypass-detection behavior itself, but does confirm this Trigger's CEL now survives
  contact with real, mixed webhook traffic instead of erroring on it.

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
