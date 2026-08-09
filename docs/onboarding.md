# Onboarding a repo

Phase 3 item 7 replaced the fully-manual, five-separate-hand-`kubectl apply` onboarding
process with three Helm charts. `cicd.yaml` itself is the app chart's values file -
every resource the platform creates for an Application conditionally renders off what
`cicd.yaml` actually declares (see
[charts/platform-cicd-app/templates/_helpers.tpl](../charts/platform-cicd-app/templates/_helpers.tpl)'s
`platform-cicd-app.hasStage`), which is the direct fix for a real, live-confirmed bug:
a `release` PipelineRun once fired for an Application whose `cicd.yaml` never declared a release
stage, because nothing previously read `pipeline:` at all.

Full self-service (a developer onboards themselves by opening a PR) is a later, separate
step - an ArgoCD ApplicationSet git generator scanning a `Applications/*.yaml` directory - not
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

## Onboarding one Application

1. **Register the repo with Pipelines-as-Code.** Create a PaC `Repository` CR pointing at
   the app's GitHub repo (requires the platform's GitHub App - see
   [bootstrap.md](bootstrap.md) - to be installed on that repo first). Same manual step as
   before; not something a Helm chart owns.

2. **Add `cicd.yaml`** to the repo root (see
   [user-guide/quickstart.md](user-guide/quickstart.md) and
   [user-guide/examples/](user-guide/examples/README.md)) - this is the only file the
   developer maintains going forward, and it's also what you're about to pass to
   `helm install` below.

3. **Write a small `platform-identity.yaml`** - the handful of infra-identity values that
   aren't really pipeline configuration, so `schemas/cicd.schema.json` never needs to
   carry them:

   ```yaml
   platformIdentity:
     appName: <app-name>
     type: app  # or infra - see docs/naming-conventions.md
     gitopsRepoUrl: https://github.com/<org>/gitops-<app-name>  # only needed if pipeline: declares a release stage
     appRepoUrl: https://github.com/<org>/<app-name>            # only needed if ephemeralEnvironments.pullRequest.enabled
     githubOwner: <org>
   ```

   There is no `tenantNamespace` field to set - the Application's own CI/CD execution
   namespace is COMPUTED from `type`+`appName` as `<type>-<app-name>-cicd` (`type` is
   `app` for a regular application, `infra` for a shared/platform-adjacent service
   onboarded with its own pipeline), so it structurally cannot drift from the convention.
   See [naming-conventions.md](naming-conventions.md) for the full convention, including
   how deploy/staging/PR namespaces are PEERS of this one under the same flat
   `<type>-<app-name>-<env>` pattern, not built on top of it.

   `platformIdentity` is not a key `schemas/cicd.schema.json` permits - its
   `additionalProperties: false` already rejects any `cicd.yaml` that tries to define it,
   so this can never be silently overridden by a developer's own config, independent of
   which file is passed to `helm install` first or last.

4. **Provision the dev Deployment (and any other declared env) first.** `deploy-manifests.yaml`
   expects a `Deployment` named `<app-name>` to already exist in `<type>-<app-name>-<env>`
   for every environment `cicd.yaml`'s `deploy.lowerEnvironments`/`upperEnvironments` names
   (it patches the image and waits for rollout - it does not create the Deployment or its
   namespace). Apply a minimal Deployment/Service manifest by hand; a Crossplane
   `Application` composition creating this automatically remains a later step (see
   [architecture-plan.md](architecture-plan.md) - this is the one piece of onboarding the
   Helm-chart work deliberately did not take over, see that doc's own note on why).

   This has to happen **before** step 5 below, not after - confirmed live: `helm install`
   fails outright ("namespaces \"<type>-<app-name>-dev\" not found") because
   `env/deploy-rbac.yaml` grants `pipeline-runner` a namespaced Role inside that env
   namespace, and Kubernetes can't create a namespaced RBAC object in a namespace that
   doesn't exist yet. If `cicd.yaml` also declares a `release` stage, do the equivalent for
   the gitops repo now too - see [release.md](release.md)'s "Create the gitops-\<app-name\>
   repo" step for the `<app-name>/staging/deployment.yaml` + `service.yaml` it needs
   pre-seeded (the platform delivers the governance-check `.tekton/` files there
   automatically in step 6 below, but not these two - it has no way to know your
   Deployment's shape).

5. **Install the app chart:**

   ```
   helm upgrade --install <type>-<app-name>-cicd charts/platform-cicd-app \
     --namespace <type>-<app-name>-cicd --create-namespace \
     -f <app-repo>/cicd.yaml -f platform-identity.yaml --wait
   ```

   This creates `pipeline-runner` and its RBAC, only the stage-transition Triggers
   `cicd.yaml` actually declares, env-deploy RBAC for each declared environment, the
   build-cache PVC (always - see that template's own comment for why this one is
   unconditional even though `build.cache.enabled` gates whether it's actually used), the
   release AppProject/Application/DORA RBAC (if `release` is declared), the ephemeral-envs
   ApplicationSet/PR-token-refresher (if `ephemeralEnvironments.pullRequest.enabled`), the
   governance policy ConfigMap (if `governance.policyCheck`), and an `ExternalSecret` for
   `registry-credentials` (see [secrets-management.md](secrets-management.md)). Re-running
   this same command after editing `cicd.yaml` is exactly how you change an Application's
   shape later - `helm upgrade` prunes whatever a stage removal makes unnecessary, it
   doesn't just add.

6. **Deliver the `.tekton/` boilerplate.** Trigger a real push to the app repo's `cicd.yaml`
   once (or wait for the next real one) - `onboarding-resync.yaml` (delivered from
   `charts/platform-cicd-app/files/onboarding-templates/app-repo/`) fires on exactly
   that, and `charts/platform-cicd-catalog/templates/tasks/deliver-onboarding-files.yaml` opens a PR
   against the app repo (and, if a `gitopsRepoUrl` was given, the gitops repo too) with the
   generated `.tekton/*.yaml` files. Merge it once; you never hand-edit these files. This
   replaces both the old fully-manual copy-paste step and an earlier considered design (an
   ArgoCD Application reading `cicd.yaml` live from every app repo) that was rejected
   because it would need standing ArgoCD read access to every Application's source repo as a
   base requirement of onboarding itself - see this same mechanism's own header comment for
   the full reasoning. If you don't want to wait for a real commit, you can also run the
   `onboarding-resync` Pipeline directly (it has no workspaces of its own to declare -
   `deliver-onboarding-files.yaml` clones into a step-local `mktemp -d`, not the Pipeline's
   `source` workspace):

   ```
   kubectl create -f - <<EOF
   apiVersion: tekton.dev/v1
   kind: PipelineRun
   metadata:
     generateName: onboarding-resync-bootstrap-
     namespace: <type>-<app-name>-cicd
   spec:
     pipelineRef:
       resolver: cluster
       params:
         - { name: kind, value: pipeline }
         - { name: name, value: onboarding-resync }
         - { name: namespace, value: platform-catalog }
     params:
       - { name: git-url, value: "<app-repo-url>" }
       - { name: app-namespace, value: "<type>-<app-name>-cicd" }
       - { name: app-name, value: "<app-name>" }
       - { name: github-owner, value: "<org>" }
       - { name: gitops-repo-url, value: "<gitops-repo-url-or-empty>" }
     taskRunTemplate:
       serviceAccountName: pipeline-runner
     timeouts:
       pipeline: "10m"
   EOF
   ```

7. Push to `main`. Watch `pipelines-overview.json` and the Mission Control dashboard in
   Grafana.

## Keeping onboarding boilerplate in sync

Two things used to go stale silently, with no mechanism to catch either: an Application's
`cicd.yaml` changing (nothing re-rendered the app chart), and the platform's own
onboarding templates changing (nothing re-delivered already-onboarded repos' copies).
Both are the same problem now: `onboarding-resync.yaml` fires whenever `cicd.yaml`
changes on a push to `main` (a real, documented Pipelines-as-Code CEL extension,
`"cicd.yaml".pathChanged()` - not a custom filter), and re-delivers the current
`charts/platform-cicd-app/files/onboarding-templates/` content regardless of which
side went stale. Those templates are baked into a ConfigMap
(`charts/platform-cicd-app/templates/configmaps/onboarding-templates.yaml`, one copy
per Application), not the toolbox image, so an edit takes effect on that Application's
own next `helm upgrade` - no image rebuild needed, though (unlike the shared catalog
chart) it does mean updating N already-onboarded Applications individually to actually
propagate a template change, the same as any other app-chart-rendered resource.
`git status --porcelain` inside `deliver-onboarding-files.yaml` skips opening a PR when
nothing actually changed, so this is safe to fire often.

For the app chart's own resources (Triggers, RBAC, etc.) re-rendering on a `cicd.yaml`
change: that's a separate `helm upgrade` invocation, not automated yet by this same
trigger - see step 4 above. Wiring `onboarding-resync` to also re-run `helm upgrade` is a
natural next step, not built in this pass.
