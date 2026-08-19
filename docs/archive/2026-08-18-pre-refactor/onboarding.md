# Onboarding a repo

Phase 3 item 7 replaced the fully-manual, five-separate-hand-`kubectl apply` onboarding
process with three Helm charts. `cicd.yaml` itself is the app chart's values file -
every resource the platform creates for an Application conditionally renders off what
`cicd.yaml` actually declares (see
[charts/platform-cicd-app/templates/_helpers.tpl](../charts/platform-cicd-app/templates/_helpers.tpl)'s
`platform-cicd-app.hasStage`), which is the direct fix for a real, live-confirmed bug:
a `release` PipelineRun once fired for an Application whose `cicd.yaml` never declared a release
stage, because nothing previously read `pipeline:` at all.

**Now ArgoCD-managed** (previously: admin runs `helm upgrade --install` by hand for every
onboard/edit - see git history if you need the old manual-install instructions). An
ArgoCD `ApplicationSet` (`charts/platform-cicd-control-plane/templates/argocd/
tenant-onboarding-applicationset.yaml`) generates one `Application` per tenant from a git
`files` generator scanning `tenants/*/identity.yaml` in this repo - onboarding a new
Application, or changing an existing one's `platformIdentity`, is now "add/edit a file in
`tenants/`, get it reviewed" rather than a manual CLI command. See "Onboarding one
Application" below for the full per-tenant layout, and this file's own header comment for
why `platformIdentity` deliberately isn't read live from the app repo the way `cicd.yaml`
functionally is elsewhere in this platform.

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

1. **Install the platform's GitHub App on the app's repo** (see
   [bootstrap.md](bootstrap.md)) - the one manual, GitHub-side prerequisite left. The PaC
   `Repository` CR itself (pointing at the app's repo, and at its gitops repo if
   `gitopsRepoUrl` is set) is now rendered by the chart -
   `charts/platform-cicd-app/templates/pipelines-as-code/repository.yaml`, gated on
   `platformIdentity.registerPipelinesAsCode` (default `true`) - not a separate manual
   step anymore. This is also what the ephemeral-envs `pullRequest` generator's
   token-refresher and the release stage's `open-release-pr.yaml` both depend on (see
   that template's header comment).

2. **Add `cicd.yaml`** to the repo root (see
   [user-guide/quickstart.md](user-guide/quickstart.md) and
   [user-guide/examples/](user-guide/examples/README.md)) - this is the only file the
   developer maintains going forward, and the only onboarding file that lives in the app
   repo at all. The `tenant-onboarding` `ApplicationSet` reads it live from here (see
   step 5) - a push to `main` takes effect on ArgoCD's next sync, no separate copy to
   keep up to date anywhere.

3. **Add `tenants/<app-name>/identity.yaml`** to **this repo** (`platform-cicd`, via a
   PR an operator reviews - never the app repo) - the handful of infra-identity values
   that aren't really pipeline configuration, so `schemas/cicd.schema.json` never needs
   to carry them, AND that must never become something a developer's own commit can
   influence (see the header comment on any existing `tenants/*/identity.yaml` file for
   the full reasoning - it flows straight into governance policy-config lookups, secret
   resolution, and which `gitops-<app>` repo a release PR targets):

   ```yaml
   platformIdentity:
     appName: <app-name>
     type: app  # or infra - see docs/naming-conventions.md
     gitopsRepoUrl: https://github.com/<org>/gitops-<app-name>  # "" if no release stage
     appRepoUrl: https://github.com/<org>/<app-name>            # ALWAYS required now - see below
     githubOwner: <org>
     catalogNamespace: platform-catalog
   ```

   All six fields must be present (even as `""`) - the ApplicationSet's own Go-template
   evaluation of these generator params errors on a genuinely-missing key for every
   tenant, not just this one; see any `tenants/*/identity.yaml` file's header for why.
   `appRepoUrl` specifically can no longer be `""` for any tenant - the ApplicationSet's
   second source reads `cicd.yaml` live from exactly this URL (see step 5), not just
   when `ephemeralEnvironments.pullRequest.enabled`.

   There is no `tenantNamespace` field to set - the Application's own CI/CD execution
   namespace is COMPUTED from `type`+`appName` as `<type>-<app-name>-cicd` (`type` is
   `app` for a regular application, `infra` for a shared/platform-adjacent service
   onboarded with its own pipeline), so it structurally cannot drift from the convention.
   See [naming-conventions.md](naming-conventions.md) for the full convention, including
   how deploy/staging/PR namespaces are PEERS of this one under the same flat
   `<type>-<app-name>-<env>` pattern, not built on top of it.

   `platformIdentity` is not a key `schemas/cicd.schema.json` permits - its
   `additionalProperties: false` already rejects any `cicd.yaml` that tries to define it,
   so this can never be silently overridden by a developer's own config - not just by
   convention, but structurally: the ApplicationSet's Helm `valuesObject` (built only
   from this file) takes real precedence over `valueFiles` (the app repo's `cicd.yaml`,
   read live) for any overlapping key, confirmed by a real live test, not assumed - see
   the ApplicationSet's own header comment. `cicd.yaml` itself needs nothing added here;
   step 5 reads it straight from the app repo.

4. **Provision the dev Deployment (and any other declared env) first.** `deploy-manifests.yaml`
   expects a `Deployment` named `<app-name>` to already exist in `<type>-<app-name>-<env>`
   for every environment `cicd.yaml`'s `deploy.lowerEnvironments`/`upperEnvironments` names
   (it patches the image and waits for rollout - it does not create the Deployment or its
   namespace). Apply a minimal Deployment/Service manifest by hand; a Crossplane
   `Application` composition creating this automatically remains a later step (see
   [architecture-plan.md](architecture-plan.md) - this is the one piece of onboarding the
   Helm-chart work deliberately did not take over, see that doc's own note on why).

   This has to happen **before** step 5 below, not after - confirmed live (back when this
   step was a manual `helm install`, and unchanged now that ArgoCD does it): the sync
   fails outright ("namespaces \"<type>-<app-name>-dev\" not found") because
   `env/deploy-rbac.yaml` grants `pipeline-runner` a namespaced Role inside that env
   namespace, and Kubernetes can't create a namespaced RBAC object in a namespace that
   doesn't exist yet. `syncOptions: CreateNamespace=true` on the ArgoCD `Application`
   only creates ITS OWN `<type>-<app-name>-cicd` namespace, not each declared env's - this
   step is still a real manual prerequisite. If `cicd.yaml` also declares a `release`
   stage, do the equivalent for the gitops repo now too - see [release.md](release.md)'s
   "Create the gitops-\<app-name\>-repo" step for what it needs pre-seeded (the platform
   delivers the governance-check `.tekton/` files there automatically in step 6 below,
   but not the app's own manifest content - it has no way to know your workload's shape).

5. **ArgoCD installs the app chart** - nothing to run by hand. Once step 3's
   `tenants/<app-name>/identity.yaml` lands on `platform-cicd`'s default branch, the
   `tenant-onboarding` `ApplicationSet` (`charts/platform-cicd-control-plane/
   templates/argocd/tenant-onboarding-applicationset.yaml`) picks it up on its next poll
   and creates/syncs a two-source `Application` named `<app-name>-cicd` in the `argocd`
   namespace - one source is this platform's own chart, the other reads `cicd.yaml` live
   from `appRepoUrl` (step 2's file, no separate copy). Check
   `kubectl get application <app-name>-cicd -n argocd` for sync status if it doesn't show
   healthy within a few minutes.

   This creates `pipeline-runner` and its RBAC, only the stage-transition Triggers
   `cicd.yaml` actually declares, env-deploy RBAC for each declared environment, the
   build-cache PVC (always - see that template's own comment for why this one is
   unconditional even though `build.cache.enabled` gates whether it's actually used), the
   release AppProject/Application/DORA RBAC (if `release` is declared), the ephemeral-envs
   ApplicationSet/PR-token-refresher (if `ephemeralEnvironments.pullRequest.enabled`), the
   governance policy ConfigMap (always - the release-gate commit-signature check runs
   unconditionally regardless of `governance.policyCheck`), and an `ExternalSecret` for
   `registry-credentials` (see [secrets-management.md](secrets-management.md)). Editing
   `cicd.yaml` (step 2) and letting ArgoCD auto-sync is exactly how you change an
   Application's shape later - no separate copy to update, no `helm upgrade` to remember;
   the `Application`'s `prune: true` removes whatever a stage removal makes unnecessary.

6. **Deliver the `.tekton/` boilerplate.** Trigger a real push to the app repo's `cicd.yaml`
   once (or wait for the next real one) - `onboarding-resync.yaml` (delivered from
   `charts/platform-cicd-app/files/onboarding-templates/app-repo/`) fires on exactly
   that, and `charts/platform-cicd-catalog/templates/tasks/deliver-onboarding-files.yaml` opens a PR
   against the app repo (and, if a `gitopsRepoUrl` was given, the gitops repo too) with the
   generated `.tekton/*.yaml` files. Merge it once; you never hand-edit these files. This
   replaces the old fully-manual copy-paste step, and stays PaC-triggered rather than
   ArgoCD-driven even now that step 5 has ArgoCD reading `cicd.yaml` live for the chart's
   own values - a genuinely separate concern (delivering files INTO the app/gitops repos,
   not reading FROM one), see this same mechanism's own header comment for the original
   reasoning. If you don't want to wait for a real commit, you can also run the
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
change: **closed** as of the ArgoCD-managed onboarding redesign (see "Onboarding one
Application" step 5 above) - the `tenant-onboarding` `ApplicationSet`'s generated
`Application` reads `cicd.yaml` live from the app repo (a revisited decision; see that
ApplicationSet's own header comment for why an earlier version used a tracked copy
instead, and why that changed), so a `cicd.yaml` push now reaches both halves - the
boilerplate-delivery mechanism described above, and the chart's own rendered resources -
without a manual step or a copy to keep in sync anywhere.

**A real deadlock this mechanism can fall into, found and fixed live (2026-08-11)**:
`onboarding-resync`'s own trigger file - the thing that would deliver a fix - is ITSELF
one of the files this mechanism regenerates. If a required param gets added to
`onboarding-resync.yaml`'s Pipeline (or `release.yaml`'s, since a stale
`flow-<name>.yaml` hits the same class of failure) after a tenant already onboarded, that
tenant's stale trigger file doesn't pass the new param - so the very PipelineRun that
would regenerate it fails Tekton admission (`ParameterMissing`) before ever running.
Nothing can self-heal at that point without manual intervention. Fixed by making
`onboarding-resync.yaml`'s own params optional wherever derivable (`app-type`, from
`app-namespace`'s own `<type>-<app-name>-cicd` convention -
`deliver-onboarding-files.yaml`'s own header has the exact fallback) - a stale trigger
file that omits a since-added param now still runs successfully instead of deadlocking.
**Lesson for next time a required param is added to any Pipeline a stale
`.tekton/`-committed trigger file might invoke**: either give it a derivable default
here too, or accept that every already-onboarded tenant needs a manual one-time
`onboarding-resync` PipelineRun fired by hand (same as this incident) before the fix can
reach them on its own.
