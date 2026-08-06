# PR-based ephemeral environments

Any PR against `nodejs-demo-app` labeled `preview` gets a real, running, isolated
environment - its own namespace, its own `Deployment`/`Service`, running the exact image
that PR's own build produced - torn down automatically when the PR closes or the label
is removed. This is modeled on a real prior production pattern (ArgoCD ApplicationSet's
`pullRequest` generator, `gitops-main/charts/cd-pipelines-user/templates/appset-
ephemeral-envs-pr.yaml`, analyzed live), keeping the generator mechanism itself (it was
sound) while fixing two things that mechanism's supporting pieces got wrong in
production - see "What's different from the old system" below.

## Flow

```
developer adds the `preview` label to a PR on nodejs-demo-app
  -> within ~180s, ArgoCD's ApplicationSet pullRequest generator (polling GitHub,
     label-gated) picks it up
  -> generates an Application named nodejs-demo-app-pr-<number>, sourced from
     nodejs-demo-app's own k8s/ephemeral/ Kustomize base at that PR's head SHA
  -> kustomize.nameSuffix ("-<number>") and kustomize.images (pointed at that PR's
     already-built, uniquely-tagged image) are applied at generation time - nothing in
     the repo needs per-PR editing
  -> Application syncs into platform-cicd-demo-pr-<number>, a namespace that is itself
     one of the synced resources (see "Why the namespace is tracked, not
     CreateNamespace=true" below)
  -> developer: kubectl port-forward -n platform-cicd-demo-pr-<number> svc/nodejs-demo-app <port>:80
  -> PR closed, or `preview` label removed
  -> generator stops returning that PR -> ArgoCD deletes the generated Application ->
     resources-finalizer.argocd.argoproj.io cascade-deletes everything it tracks,
     including the namespace
```

## Why the namespace is tracked, not `CreateNamespace=true`

Verified live against this cluster before trusting it for real PRs: a throwaway
`Application` with `syncPolicy.syncOptions: [CreateNamespace=true]` and the
`resources-finalizer.argocd.argoproj.io` finalizer, on deletion, correctly cascade-
deleted its `Deployment`/`Service` but left the auto-created namespace `Active` forever
- `CreateNamespace=true` is a sync-time convenience, not something that adds the
namespace to the Application's own tracked-resource set. This is the exact bug the old
system hit (see below) and never fixed.

The fix, also verified live: include the `Namespace` as an actual manifest in the synced
source (`k8s/ephemeral/namespace.yaml` in `nodejs-demo-app`) so it becomes a real tracked
resource. A second live test with this in place confirmed the finalizer then deletes the
namespace along with everything else. `k8s/ephemeral/namespace.yaml`'s own comments
carry this same explanation for anyone editing it later.

## What's different from the old system

Live analysis of the old system's `appset-ephemeral-envs-pr.yaml` and siblings found the
ApplicationSet `pullRequest` generator itself sound and worth porting as-is, but two
supporting pieces were real, confirmed failures in production, not just theoretical
risk - fixed here rather than repeated:

- **Cleanup was explicitly disabled.** Commit `c54ce8f5` in the old repo comments out the
  finalizer that would have cascade-deleted a PR's namespace, while the comment directly
  above it still describes the now-disabled behavior. Every PR-based ephemeral namespace
  that system ever created was orphaned forever - there was no TTL backstop either (the
  one that existed was gated to branch-based envs only). Here: the finalizer is verified
  live (above) and there's a TTL backstop regardless (below) - not a single point of
  failure this time.
- **RBAC used `cluster-admin`** on the pipeline ServiceAccount managing ephemeral envs (a
  narrower ClusterRole existed in the same chart but was dead code, never bound to
  anything). Here: no Tekton pipeline ServiceAccount needs any new RBAC at all for this
  feature - ArgoCD's own already-trusted `applicationset-controller` does all
  namespace/Application creation. The only new RBAC is the token-refresher CronJob's
  narrowly-scoped access to exactly one named Secret in `argocd` (see below).

Also different: images are tagged per-PR-per-SHA already (`charts/platform-cicd-catalog/templates/tasks/build-image.yaml`
truncates to 12 characters - confirmed live, no fix was actually needed here despite the
plan initially assuming otherwise), so the ApplicationSet template's `kustomize.images`
points at a real, already-pushed image via `{{ trunc 12 .head_sha }}`, not a shared
mutable tag or a GitHub-Actions-workflow-file-commit trick like the old system used.

## Credential for the ApplicationSet generator

ArgoCD's `pullRequest.github.tokenRef` reads from a static Secret - the generator's own
controller polls GitHub independently, not through a live per-call exchange like
`open-release-pr.yaml` uses for the release stage. Rather than a new long-lived PAT,
`pr-token-refresher-cronjob.yaml` runs every 20 minutes (comfortably inside a GitHub App
installation token's 1-hour lifetime) as a dedicated `pr-env-token-refresher`
ServiceAccount in the tenant's own namespace, calls the same
`/github-installation-token` endpoint built for the release stage, and writes the result
into `<app-name>-pr-generator-token` in `argocd` - the only thing it's allowed to touch
there (`create` unscoped since the Secret doesn't exist yet the first time, `get`/
`update`/`patch` scoped by `resourceNames` after that).

This required one real change to `token-review-interceptor`: `verifyTenantOwnsGitOpsRepo`
only authorized a tenant to mint a token for its own `gitops-<app-name>` repo. Renamed to
`verifyTenantOwnsRepo` and extended to also match the tenant's app repo directly (the
generator needs to list PRs on `nodejs-demo-app` itself, not a gitops repo) - authorized
the same way, via the tenant's own `Repository` CR, just matching the app-repo name
directly instead of requiring the `gitops-` prefix. Verified live post-rebuild: app-repo
token request succeeds, the existing gitops-repo path still works unchanged, and a
request for an unrelated repo still gets rejected.

## TTL backstop

`pr-namespace-ttl-sweep-cronjob.yaml` is a single shared, platform-level CronJob (applied
once, not per tenant) in `platform-system`, running every 30 minutes: lists every
namespace labeled `platform.io/ephemeral-env=true` across all tenants and deletes any
older than `TTL_HOURS` (24) by `metadata.creationTimestamp`. This exists purely as a
backstop to the finalizer, which is verified live above - a namespace surviving 24h
despite that is far more likely to be something stuck than a still-legitimately-open PR,
so no live GitHub check is needed here, just age + the label. RBAC is cluster-scoped by
necessity (`Namespace` has no namespaced form) but deliberately narrow:
`list`/`get`/`delete` on `namespaces` only.

The old system had an equivalent sweep for its branch-based ephemeral envs but never
extended it to PR-based ones - the label this sweep selects on
(`platform.io/ephemeral-env: "true"`, set in `k8s/ephemeral/namespace.yaml`) exists from
day one here specifically so this gap can't recur.

## A real gap this surfaced: Kustomize's `nameSuffix` skips `Namespace` objects

Verified live: Kustomize's built-in name-transformer deliberately excludes `Namespace`
from `nameSuffix`/`namePrefix` (confirmed via `kubectl kustomize` against the base with
just `nameSuffix` set - every other resource got suffixed, the `Namespace` didn't). Since
`destination.namespace` (`<TENANT>-pr-{{.number}}`) is set independently in the
ApplicationSet template spec, this produced a real, reproducible failure on the first
live PR test: the `Namespace` synced as `<TENANT>-pr` (unsuffixed) while the `Deployment`/
`Service` were targeted at `<TENANT>-pr-{{.number}}`, which never existed - sync failed
with `namespace ... not found`, retried, never converged.

Fixed with an explicit Kustomize JSON6902 `patches` entry in the ApplicationSet template,
templated the same way `nameSuffix`/`images` already are, that renames the `Namespace`
object directly:
```yaml
patches:
  - target: { kind: Namespace, name: <TENANT>-pr }
    patch: |-
      - op: replace
        path: /metadata/name
        value: <TENANT>-pr-{{.number}}
```
Also confirmed live that ArgoCD correctly prunes the old (wrongly-named) `Namespace` once
the Application's tracked-resource set changes to the corrected name - the rename itself
doesn't leave an orphan behind.

## A real gap this surfaced: newly-created GHCR packages default to private

The very first push to a new `image-repo` name (e.g. `nodejs-demo-app-pr`, the first time
any PR ever builds) auto-creates that GHCR package as **private**, regardless of the
linked repo's own visibility - confirmed live via a real `403 Forbidden` fetching an
anonymous pull token, even though the sibling `nodejs-demo-app` package (already public)
pulls with no pull secret anywhere. This is a one-time, per-image-repo-name event, not a
per-build or per-PR one - GHCR doesn't reset visibility on subsequent pushes to an
already-existing package. Fix: flip visibility to public once, right after the first-ever
build of a new app's `-pr` image (see step 6 below) - a one-time onboarding step, same
category as installing the PaC App or configuring branch protection, not new platform
code. (Automating this via the GitHub Packages API is possible but wasn't worth the added
`packages:write` App-permission scope and per-push API call for something that only ever
needs to happen once per app.)

## Onboarding a tenant for ephemeral environments (per app)

One-time setup per app, same spirit as the release stage's onboarding steps.

1. **Push `nodejs-demo-app`'s new `k8s/ephemeral/` directory** (`namespace.yaml`,
   `deployment.yaml`, `service.yaml`, `kustomization.yaml`) - no PR needed unless the repo
   has branch protection configured (it doesn't currently, unlike `gitops-nodejs-demo-app`).

2. **Apply the ApplicationSet + AppProject template**, with `<TENANT>`, `<APP_NAME>`,
   `<APP_REPO_URL>`, `<GITHUB_OWNER>` substituted:
   ```
   sed -e 's#<TENANT>#platform-cicd-demo#g' -e 's#<APP_NAME>#nodejs-demo-app#g' \
       -e 's#<APP_REPO_URL>#https://github.com/jfillman/nodejs-demo-app#g' \
       -e 's#<GITHUB_OWNER>#jfillman#g' \
     charts/platform-cicd-tenant/templates/argocd/ephemeral-envs.yaml | kubectl apply -f -
   ```
   This updates the tenant's existing `AppProject` (the same one the release stage's
   staging `Application` already uses) in place - it does not create a second, competing
   `AppProject`.

3. **Apply the token-refresher CronJob**, same substitutions:
   ```
   sed -e 's#<TENANT>#platform-cicd-demo#g' -e 's#<APP_NAME>#nodejs-demo-app#g' \
       -e 's#<GITHUB_OWNER>#jfillman#g' \
     charts/platform-cicd-tenant/templates/argocd/ephemeral-envs.yaml | kubectl apply -f -
   ```

4. **Apply the TTL sweep CronJob** - once per cluster, not per tenant:
   ```
   kubectl apply -f charts/platform-cicd-control-plane/templates/argocd/pr-namespace-ttl-sweep-cronjob.yaml
   ```

5. **Bootstrap the generator's token Secret once**, rather than waiting up to 20 minutes
   for the CronJob's first scheduled run:
   ```
   kubectl create job --from=cronjob/nodejs-demo-app-pr-token-refresher \
     nodejs-demo-app-pr-token-refresher-bootstrap -n platform-cicd-demo
   ```

6. **After the first real PR build completes**, flip the new `<app-name>-pr` GHCR
   package's visibility to public (Package settings -> Change visibility) - see "A real
   gap this surfaced: newly-created GHCR packages default to private" above. One-time,
   not needed again for this app.

## Access

`kind-observe` has no ingress/DNS (an already-documented platform gap), so there's no
clickable preview URL to post as a PR comment - access is `kubectl port-forward` into the
PR's namespace, same as every other environment on this cluster. Note the Service name
also gets the `-{{.number}}` suffix (nameSuffix applies normally to it, unlike Namespace):
```
kubectl port-forward -n platform-cicd-demo-pr-<number> svc/nodejs-demo-app-<number> 8080:80
```

## Verification

- Label a real PR `preview` on `nodejs-demo-app`. Within ~180s (the generator's
  `requeueAfterSeconds`), `kubectl get application.argoproj.io -n argocd` should show
  `nodejs-demo-app-pr-<number>`, and `kubectl get ns platform-cicd-demo-pr-<number>`
  should exist with a running pod on that PR's own uniquely-tagged image.
- `kubectl port-forward` into it and confirm the PR's actual code is running (not just
  any deploy).
- Close the PR (or remove the label) and confirm both the `Application` and the
  namespace are actually gone within the poll interval, not just `Terminating`.
- Security check: from `platform-cicd-demo`'s SA, request a token for a repo the tenant
  doesn't own via `/github-installation-token` - should still be rejected (403), same as
  the release-stage check.
