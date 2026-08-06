# Onboarding a repo

Phase 3 item 7 replaced the fully-manual, five-separate-hand-`kubectl apply` onboarding
process with three Helm charts. `cicd.yaml` itself is the tenant chart's values file -
every resource the platform creates for a tenant conditionally renders off what
`cicd.yaml` actually declares (see
[charts/platform-cicd-tenant/templates/_helpers.tpl](../charts/platform-cicd-tenant/templates/_helpers.tpl)'s
`platform-cicd-tenant.hasStage`), which is the direct fix for a real, live-confirmed bug:
a `release` PipelineRun once fired for a tenant whose `cicd.yaml` never declared a release
stage, because nothing previously read `pipeline:` at all.

Full self-service (a developer onboards themselves by opening a PR) is a later, separate
step - an ArgoCD ApplicationSet git generator scanning a `tenants/*.yaml` directory - not
built yet. Today, onboarding is still admin-run, just versioned, testable, and prunable
instead of five hand-substituted files nothing ever removes.

## One-time platform setup (already done if you ran `hack/bootstrap.sh`)

The control plane and catalog charts are cluster-wide singletons, installed once:

```
helm upgrade --install platform-cicd-control-plane charts/platform-cicd-control-plane \
  --namespace platform-system --create-namespace --wait
helm upgrade --install platform-cicd-catalog charts/platform-cicd-catalog \
  --namespace platform-catalog --create-namespace --wait
```

See [catalog-versioning.md](catalog-versioning.md) for how catalog changes get tested and
promoted afterward, and [secrets-management.md](secrets-management.md) for the one manual
step this doesn't cover (populating the ClusterSecretStore's source namespace with real
credentials).

## Onboarding one tenant/app

1. **Register the repo with Pipelines-as-Code.** Create a PaC `Repository` CR pointing at
   the app's GitHub repo (requires the platform's GitHub App - see
   [bootstrap.md](bootstrap.md) - to be installed on that repo first). Same manual step as
   before; not something a Helm chart owns.

2. **Add `cicd.yaml`** to the repo root (see [examples/cicd.yaml](examples/cicd.yaml)) -
   this is the only file the developer maintains going forward, and it's also what you're
   about to pass to `helm install` below.

3. **Write a small `platform-identity.yaml`** - the handful of infra-identity values that
   aren't really pipeline configuration, so `schemas/cicd.schema.json` never needs to
   carry them:

   ```yaml
   platformIdentity:
     tenantNamespace: <tenant>
     appName: <app-name>
     gitopsRepoUrl: https://github.com/<org>/gitops-<app-name>  # only needed if pipeline: declares a release stage
     appRepoUrl: https://github.com/<org>/<app-name>            # only needed if ephemeralEnvironments.pullRequest.enabled
     githubOwner: <org>
   ```

   `platformIdentity` is not a key `schemas/cicd.schema.json` permits - its
   `additionalProperties: false` already rejects any `cicd.yaml` that tries to define it,
   so this can never be silently overridden by a developer's own config, independent of
   which file is passed to `helm install` first or last.

4. **Install the tenant chart:**

   ```
   helm upgrade --install <tenant> charts/platform-cicd-tenant \
     --namespace <tenant> --create-namespace \
     -f <app-repo>/cicd.yaml -f platform-identity.yaml --wait
   ```

   This creates `pipeline-runner` and its RBAC, only the stage-transition Triggers
   `cicd.yaml` actually declares, env-deploy RBAC for each declared environment, the
   build-cache PVC (if `build.cache.enabled`), the release AppProject/Application/DORA
   RBAC (if `release` is declared), the ephemeral-envs ApplicationSet/PR-token-refresher
   (if `ephemeralEnvironments.pullRequest.enabled`), the governance policy ConfigMap (if
   `governance.policyCheck`), and an `ExternalSecret` for `registry-credentials` (see
   [secrets-management.md](secrets-management.md)). Re-running this same command after
   editing `cicd.yaml` is exactly how you change a tenant's shape later - `helm upgrade`
   prunes whatever a stage removal makes unnecessary, it doesn't just add.

5. **Deliver the `.tekton/` boilerplate.** Trigger a real push to the app repo's `cicd.yaml`
   once (or wait for the next real one) - `onboarding-templates/.tekton/onboarding-resync.yaml`
   fires on exactly that, and `charts/platform-cicd-catalog/templates/tasks/deliver-onboarding-files.yaml` opens a PR
   against the app repo (and, if a `gitopsRepoUrl` was given, the gitops repo too) with the
   generated `.tekton/*.yaml` files. Merge it once; you never hand-edit these files. This
   replaces both the old fully-manual copy-paste step and an earlier considered design (an
   ArgoCD Application reading `cicd.yaml` live from every app repo) that was rejected
   because it would need standing ArgoCD read access to every tenant's source repo as a
   base requirement of onboarding itself - see this same mechanism's own header comment for
   the full reasoning. If you don't want to wait for a real commit, you can also run the
   `onboarding-resync` Pipeline directly:

   ```
   tkn pipeline start onboarding-resync -n <tenant> \
     -p git-url=<app-repo-url> -p tenant=<tenant> -p app-name=<app-name> \
     -p github-owner=<org> -p gitops-repo-url=<gitops-repo-url-or-empty> \
     --workspace name=source,emptyDir= \
     --serviceaccount pipeline-runner
   ```

6. **Provision the dev Deployment.** `deploy-manifests.yaml` expects a `Deployment` named
   `<app-name>` to already exist in `<tenant>-dev` (it patches the image and waits for
   rollout - it does not create the Deployment). Apply a minimal Deployment/Service
   manifest by hand; a Crossplane `Application` composition creating this automatically
   remains a later step (see [architecture-plan.md](architecture-plan.md) - this is the
   one piece of onboarding the Helm-chart work deliberately did not take over, see that
   doc's own note on why).

7. Push to `main`. Watch `pipelines-overview.json` and the Mission Control dashboard in
   Grafana.

## Keeping onboarding boilerplate in sync

Two things used to go stale silently, with no mechanism to catch either: a tenant's
`cicd.yaml` changing (nothing re-rendered the tenant chart), and the platform's own
`onboarding-templates/.tekton/*.yaml` changing (nothing re-delivered already-onboarded
repos' copies). Both are the same problem now: `onboarding-resync.yaml` fires whenever
`cicd.yaml` changes on a push to `main` (a real, documented Pipelines-as-Code CEL
extension, `.pathChanged("cicd.yaml")` - not a custom filter), and re-delivers the
current `onboarding-templates/.tekton/*` content regardless of which side went stale.
`git status --porcelain` inside `deliver-onboarding-files.yaml` skips opening a PR when
nothing actually changed, so this is safe to fire often.

For the tenant chart's own resources (Triggers, RBAC, etc.) re-rendering on a `cicd.yaml`
change: that's a separate `helm upgrade` invocation, not automated yet by this same
trigger - see step 4 above. Wiring `onboarding-resync` to also re-run `helm upgrade` is a
natural next step, not built in this pass.
