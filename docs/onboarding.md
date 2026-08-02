# Onboarding a repo (Phase 1: manual)

Full self-service onboarding via a Crossplane `Application` claim is Phase 3 -
deliberately sequenced *after* a handful of pilots are onboarded by hand, so the
Crossplane API is designed around what tenants actually vary, not guessed upfront (see
the plan's Q2 review notes). For now, onboarding a pilot repo is these steps:

1. **Namespace + tenant identity.** Create the tenant namespace (`<TENANT>`) and apply
   `platform/broker/manifests/tenant-triggers-template.yaml` with `<TENANT>` and
   `<APP_NAME>` substituted throughout - this creates the `pipeline-runner`
   ServiceAccount/Role, the scoped impersonation grant for the broker, and the two
   Trigger/TriggerBinding/TriggerTemplate sets for build->test and test->deploy
   chaining. See [chaining.md](chaining.md).

2. **Register the repo with Pipelines-as-Code.** Create a PaC `Repository` CR pointing
   at the app's GitHub repo (requires the platform's GitHub App - see
   [bootstrap.md](bootstrap.md) - to be installed on that repo first).

3. **Generate the `.tekton/` boilerplate.** Copy
   `onboarding-templates/.tekton/push.yaml` and `pull-request.yaml` into the app repo's
   `.tekton/` directory, substituting `<TENANT>`, `<APP_NAME>`, `<IMAGE_REPO>`, and open
   a PR. The developer merges it once; they never touch these files again. See the
   staleness note in [cicd-yaml-reference.md](cicd-yaml-reference.md).

4. **Add `cicd.yaml`.** Copy [examples/cicd.yaml](examples/cicd.yaml) to the repo root
   and adjust build/test/deploy settings for the app. This is the only file the
   developer maintains going forward.

5. **Provision the dev Deployment, and its RBAC.** Phase 1's `deploy-manifests` Task
   expects a `Deployment` named `<APP_NAME>` to already exist in `<TENANT>-dev` (it
   patches the image and waits for rollout - it does not create the Deployment). Apply
   a minimal Deployment/Service manifest by hand for pilots; Phase 3's `Application`
   composition is what eventually creates this automatically. `<TENANT>-dev` is a
   *different namespace* from `<TENANT>` (see [chaining.md](chaining.md) "why two
   namespaces" if that's not obvious), so `pipeline-runner`'s Role from step 1 does
   **not** cover it - also apply
   `platform/broker/manifests/tenant-env-rbac-template.yaml` (substituting `<TENANT>`
   and `<ENV>=dev`) or `deploy-manifests.yaml` fails with `Forbidden` on its first real
   run. Repeat this template for each additional environment (`staging`, `prod`, ...)
   as they're added to `cicd.yaml`'s `deploy.upperEnvironments`.

6. **Registry credentials.** `catalog/tasks/build-image.yaml`'s kaniko step needs a
   `kubernetes.io/dockerconfigjson` Secret named `registry-credentials` in the
   **tenant's own namespace** (`<TENANT>`, not `<TENANT>-dev` - that's where build/test
   PipelineRuns actually run, per the `pipeline-runner` SA created in step 1) to push to
   a private registry:

   ```
   kubectl create secret docker-registry registry-credentials -n <TENANT> \
     --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
   ```

   If the deployed image also needs to be *pulled* from a private registry, the
   Deployment in `<TENANT>-dev` needs its own `imagePullSecrets` referencing an
   equivalent Secret in that namespace too - a token scoped to `write:packages` on
   GHCR covers both push and pull, but the Secret still has to exist in each namespace
   separately (Kubernetes Secrets aren't shared across namespaces). Making the GHCR
   package public sidesteps the pull-secret requirement entirely, at the cost of the
   image being publicly readable.

7. Push to `main`. Watch `pipelines-overview.json` in Grafana.
