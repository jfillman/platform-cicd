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

5. **Provision the dev Deployment.** Phase 1's `deploy-manifests` Task expects a
   `Deployment` named `<APP_NAME>` to already exist in `<TENANT>-dev` (it patches the
   image and waits for rollout - it does not create the Deployment). Apply a minimal
   Deployment/Service manifest by hand for pilots; Phase 3's `Application` composition
   is what eventually creates this automatically.

6. Push to `main`. Watch `pipelines-overview.json` in Grafana.
