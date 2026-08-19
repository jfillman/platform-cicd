# Secrets management

External Secrets Operator (ESO) is platform infrastructure, not just a bootstrap-time
install alongside Tekton/PaC/kube-prometheus-stack. Every chart in this platform consumes
secret material via a real `ExternalSecret`, not a hand-applied raw `Secret`.

## The backend: self-hosted Infisical

**2026-08-19: migrated off ESO's built-in `kubernetes` provider onto real Infisical.**
ESO was installed early in this platform's life but had zero configured backends until
Phase 3 item 7; the pragmatic bridge that followed (ESO's `kubernetes` provider,
mirroring real `Secret`s out of one hand-managed namespace) was always documented as a
stopgap pending "community Infisical, via Dream IDP" - that future step has arrived.
`idp-service-catalog` runs a self-hosted Infisical instance (kind-dev only) plus
`infisical-secretstore-operator`, the same mechanism idp-application-delivered apps
already use for their own runtime secrets.

The control plane gets its **own** Infisical project (not an app's), one per cluster it
runs on:

```
apiVersion: secrets.idp.io/v1alpha1
kind: InfisicalProject
metadata:
  name: platform-cicd-kind-dev
spec:
  projectName: platform-cicd-kind-dev
  slug: platform-cicd-kind-dev
  environmentSlug: shared
  credentialsSecretName: platform-cicd-infisical-creds
  authMethod: kubernetes
```

(`charts/platform-cicd-control-plane/templates/secretstore/infisical-project.yaml`).
`authMethod: kubernetes` (zero-persisted-credential, ESO's controller SA token verified
live against this cluster's own TokenReview API) is correct here because kind-dev is
also the Infisical host - see `infisicalHost`/Kubernetes-vs-Universal-Auth in
`idp/docs/service-catalog-design.md` Item 8 for the underlying mechanism this reuses. A
cluster that runs this control plane but does NOT host Infisical would need
`authMethod: universal` instead - not built, since kind-dev is currently the only
platform-cicd-control-plane install.

The resulting `ClusterSecretStore` (`platform-secret-store`, name unchanged from the old
`kubernetes`-provider version so every downstream `secretStoreRef.name` reference kept
working) points `provider.infisical` at that project, `environmentSlug: shared`,
`secretsPath: "/"` - every platform-wide key (`registry-credentials`,
`github-app-creds`, `relay-token-<cluster>` per registered upper cluster) lives flat
under that one path. **The user still plants real credential material by hand, via
Infisical directly (UI or API), never through this chart or committed to this repo** -
this changes nothing about who creates real credential material or how, only where it
lives and how every chart consumes it.

## Application-owned secrets: one secretsPath per Application, same project

An Application's own genuinely CI-specific secrets (SAST scan credentials, ...) - see
[app-secrets.md](app-secrets.md) - use the SAME `platform-cicd-kind-dev` project, not a
separate one, scoped to `/<type>/<appName>/` via a dedicated `ClusterSecretStore` per
Application (control-plane's own `appSecretStores` values list). This replaced an
earlier design where each Application's own `<type>-<appName>-dev` namespace was treated
as its secret backend (a real `Secret` created there by hand) - that meant CI/deploy
infrastructure doubled as an ad hoc vault, and every app's secrets before Infisical
lived in a namespace with a completely different purpose. Path-scoping inside one
project gives the same per-app isolation without either problem, and without coupling
an app's CI secrets to it having been onboarded through idp's `NodeJSApplication` XR
(deliberately NOT reusing idp's own per-(app,cluster) Infisical project for this - see
`app-secret-stores.yaml`'s own header).

**Exception: `slack-webhook-url`.** That one key is NOT platform-cicd's to own - it's
sourced from the app's own idp-managed `<appName>-kind-dev` project instead, the same
place `idp-application`'s own AI-triage Slack notifications already read it from. A
real mistake in this migration's first pass required app owners to plant it twice, in
two different projects - see [app-secrets.md](app-secrets.md)'s own section on this key
for the fix and the reasoning.

## registry-credentials: disseminated via ClusterExternalSecret

**2026-08-19: no longer a per-app opt-in.** Every Application used to need its own
`registry-credentials` `ExternalSecret`, rendered by the app chart (platform-cicd-app)
or, for idp-application-delivered workloads, gated behind a `registryCredentials.enabled`
values flag. Both are gone, replaced by ONE `ClusterExternalSecret`
(`charts/platform-cicd-control-plane/templates/secretstore/
registry-credentials-cluster-external-secret.yaml`, mirrored hand-authored on kind-prod
in `gitops-cluster-kind-prod/10-crds-operators/external-secrets/`), which generates the
`registry-credentials` `Secret` automatically in every namespace labeled
`platform.io/managed-secrets: "true"` - applied by ArgoCD's own
`syncPolicy.managedNamespaceMetadata` on every namespace this platform's
`tenant-onboarding` `ApplicationSet`s create (both platform-cicd's own CI namespaces and
idp's `app-<appName>-<env>` ones), re-applied every sync so it also lands on
already-existing namespaces. Every app's own `ServiceAccount` (both
`charts/platform-cicd-app/templates/identity/pipeline-runner.yaml` and
`idp-application`'s `workload/serviceaccount.yaml`) references that Secret name
unconditionally now - no per-app opt-in left to forget.

Populating the credential itself (one-time, manual, by design): plant a
`registry-credentials-dockerconfigjson` key holding the fully-rendered
`.dockerconfigjson` payload into the control plane's own Infisical project, once per
cluster - same "manual by design" posture as everything else here. A single-flat-value
key, not multiple Infisical fields extracted via `dataFrom.extract`, since ESO's real
provider behavior for that combination against Infisical wasn't confirmed live going
into this migration - safer to store the one already-shaped JSON blob and template
`kubernetes.io/dockerconfigjson` from it directly (the same pattern idp-application's
own registry-credentials template already used).

## Relay-token distribution

**2026-08-19: built for real, closing the gap [multi-cluster.md](multi-cluster.md)
tracked as deferred.** Every app onboarded to a cluster-mapped env used to need a
hand-provisioned `platform-outcome-relay-token` `Secret`, copied by hand into every
app's namespace on the upper cluster (`hack/bootstrap-upper-cluster.sh`). Now:

- The dev-cluster (verifier) side - `cluster-<name>-relay-token` `Secret`s in
  `platform-system`, which `argocd-outcome-relay` compares bearer tokens against - sync
  from `platform-cicd-kind-dev`'s Infisical project (`relay-token-<cluster>` key per
  registered cluster), via `charts/platform-cicd-control-plane/templates/clusters/
  relay-token-external-secret.yaml`.
- The upper-cluster (caller) side - `platform-outcome-relay-token`, read by the
  release-tracking hook Jobs (`catalog/lib/argocd-outcome-hook.sh`) - syncs from that
  cluster's OWN `platform-cicd-<cluster>` Infisical project, via
  `idp-service-catalog/charts/idp-application`'s `templates/release-tracking/
  relay-token-external-secret.yaml`, gated on `releaseTracking` exactly like the hook
  Jobs/RBAC it accompanies.

The token value still has to originate somewhere real - plant the same value into both
clusters' own Infisical projects by hand, once per cluster (not per app). See
[multi-cluster.md](multi-cluster.md) for the full mechanism this feeds.

## What this deliberately is not

Not a real vault beyond what Infisical itself provides - real credential material now
lives in a real secrets manager (encrypted at rest, access-controlled by real Infisical
project membership) rather than base64-encoded etcd `Secret`s, a genuine improvement
over the old `kubernetes`-provider bridge, but ESO's `refreshInterval` still just
re-syncs on a timer - it doesn't rotate the underlying credential itself.

Excluded from this migration, deliberately: `fulcio-secret`/`fulcio-server-config`
(fresh, per-cluster-generated root key material by design -
`hack/generate-cluster-values.sh` - not something "synced from a backend" makes sense
for) and PaC's own `pipelines-as-code-secret` (a third-party install's own Secret,
outside this platform's chart boundary - `github-app-creds`, this platform's own copy,
is what moved to Infisical, see [release.md](release.md)).
