# Application secrets (`secrets:`)

Lets an Application pull specific keys out of its own backend secret store into a
Kubernetes Secret its pipelines can mount - `slack-webhook-url` today, and open-ended
for whatever a future Task needs (SAST scan credentials was the second real case that
motivated building this generically instead of one-off per secret, same as
[secrets-management.md](secrets-management.md)'s `registry-credentials`).

## Where the backend store lives

**2026-08-19: migrated onto Infisical.** Each Application's own secrets now live under a
dedicated `secretsPath` (`/<type>/<appName>/`) inside the control plane's OWN Infisical
project (`platform-cicd-kind-dev` - see [secrets-management.md](secrets-management.md)),
not in a hand-created `Secret` in that Application's own dev environment namespace
(`<type>-<app-name>-dev`) the way this worked before. That namespace was CI/deploy
infrastructure doing double duty as an ad hoc vault - real per-app isolation now comes
from Infisical's own path scoping instead, with nothing app-specific added to a
namespace that has a different actual purpose.

Deliberately NOT idp-service-catalog's own per-(app,cluster) Infisical project for this
same app (the one its `NodeJSApplication` XR provisions, `<appName>-kind-dev`): reusing
it would couple an app's CI secrets (Slack webhook, SAST token) to that app having
already been onboarded through idp, which isn't true for every platform-cicd tenant.
The control plane's own project is a sibling, unrelated to whether idp onboarding has
happened for this app.

```yaml
secrets:
  - name: slack-webhook-url      # key in the resulting app-secrets Kubernetes Secret,
                                   # and the secret's name in Infisical under this app's
                                   # own secretsPath
```

No per-Application app-chart value names the backend any more (the old
`appSecretStore.secretName` field is gone) - the backend is entirely determined by
`platformIdentity.type`/`.appName`, which the app chart already requires.

## Why a ClusterSecretStore per Application, defined in the control-plane chart

An Application's own secrets need a distinct `secretsScope.secretsPath` per Application
(`/<type>/<appName>/`) - so this uses one `ClusterSecretStore` **per Application**
(`ClusterSecretStore` is cluster-scoped, matching the shape the platform-wide
`platform-secret-store` already uses; a namespaced `SecretStore` couldn't be templated
per-app from a cluster-wide chart install the same way).

These are rendered by the **control-plane chart**, not the per-Application app chart -
`charts/platform-cicd-control-plane/templates/secretstore/app-secret-stores.yaml`,
looping over the `appSecretStores` values list:

```yaml
# charts/platform-cicd-control-plane/values.yaml
appSecretStores:
  - type: app
    appName: cicd-flow-test-app
```

Each entry renders one `ClusterSecretStore` named `<type>-<appName>-secret-store`,
`secretsScope.secretsPath: /<type>/<appName>/` inside the control plane's own Infisical
project - same `hostAPI`/`auth` as the platform-wide store, just a narrower scope.
Adding a new Application here (and pushing to `main` - the control-plane chart's own
ArgoCD Application has automated selfHeal sync, no manual `helm upgrade` needed) is a
deliberate, manual, one-time-per-Application step.

**Why here and not in the app chart**: a `ClusterSecretStore` is cluster-scoped - there
is exactly one object per name, cluster-wide, and rendering it from a per-Application
Helm release (the app chart, one release per Application) is no different in kind from
any other cluster-scoped resource multiple releases might try to own. Keeping all of
them in the one control-plane release (a single owner) avoids that entirely.

**The name has to agree across two independent Helm releases**: the app chart's own
`ExternalSecret` (below) references `<type>-<appName>-secret-store` too, computed from
that Application's own `platformIdentity.type`/`.appName` - not passed between the two
charts (they're independent releases with no shared `_helpers.tpl`), but derived
identically on both sides from the same inputs both charts already require. An
Application whose `secrets:` list is non-empty but that's missing from control-plane's
`appSecretStores` list simply gets an `ExternalSecret` with nothing to sync from
(a normal ESO error status, not a hard failure of the Application's pipelines - nothing
mounts a missing key differently than an unconfigured one, see below).

## `cicd.yaml`

```yaml
secrets:
  - name: slack-webhook-url      # key in the resulting app-secrets Kubernetes Secret
  - name: sast-scan-token
    key: sast-creds-token        # only needed when the Infisical secret's own name differs
```

Each entry becomes one `data[]` entry in a single per-Application `ExternalSecret`
(`app-secrets-external-secret.yaml`), all landing in **one** target Secret
(`app-secrets`) - not one Secret per declared entry. A consuming Task always mounts the
same Secret name regardless of how many keys an Application has declared; adding a new
purpose is a `cicd.yaml` edit only, never a new volume/volumeMount anywhere. `key`
defaults to `name` - set it only when the secret's actual name in Infisical differs from
the name you want exposed as. No `remoteRef.property` - ESO's `infisical` provider
treats `property` as "extract a field from a structured/JSON secret value," not "which
flat secret to read" (confirmed live by idp-service-catalog); every secret here is an
ordinary flat value, so `key` alone is correct.

The `ExternalSecret` renders **only** when `secrets:` is non-empty - an Application
that never uses this feature gets no dangling resource.

## Consuming a declared secret from a Task

Mount the `app-secrets` Secret, `optional: true` (most Applications won't declare every
key, and the pod must still start cleanly when they don't - same graceful-skip pattern
`notify-slack.yaml` already used before this existed):

```yaml
volumes:
  - name: app-secrets
    secret:
      secretName: app-secrets
      optional: true
steps:
  - name: my-step
    volumeMounts:
      - name: app-secrets
        mountPath: /var/run/secrets/platform
        readOnly: true
    script: |
      TOKEN="$(cat /var/run/secrets/platform/sast-scan-token 2>/dev/null || true)"
      if [[ -z "${TOKEN}" ]]; then
        echo "sast-scan-token not configured, skipping"
        exit 0
      fi
```

A Secret volume mounts one file per data key, named after the key - this is exactly
what `notify-slack.yaml` already does for `slack-webhook-url`, sourced from
`app-secrets`.

## `slack-webhook-url`: what changed

Previously (see [notifications.md](notifications.md)'s "The bug this fixes"): a manual,
per-Application `kubectl create secret generic slack-webhook-url ...`, deliberately kept
outside ESO. That mechanism, and the later dev-namespace-as-backend one that replaced
it, are both gone - the backend is Infisical now.

To enable Slack notifications for an Application today:

1. Add the Application to control-plane's `appSecretStores` list (one-time, if not
   already there) and push to `main` - the `platform-cicd-control-plane` ArgoCD
   Application has automated selfHeal sync, so it picks this up on its own; no manual
   `helm upgrade` needed.
2. Declare the secret in the Application's own `cicd.yaml`:
   ```yaml
   secrets:
     - name: slack-webhook-url
   notifications:
     slack:
       enabled: true
       channel: "#your-channel"
   ```
3. Plant a `slack-webhook-url` key under this Application's own `/<type>/<appName>/`
   path in the control plane's Infisical project (`platform-cicd-kind-dev`), holding a
   real Slack incoming-webhook URL - via the Infisical UI/API, never through this chart
   or committed to this repo.

Nothing else to apply - `notify-slack.yaml`'s volume mount is already wired into every
pipeline via the existing, unconditional `notify` `finally` task.

## Verification

- `helm template`/`helm lint` both the control-plane chart (with a real
  `appSecretStores` entry) and the app chart (with and without `secrets:` set),
  confirming the `ClusterSecretStore`/`ExternalSecret` render correctly and the
  `ExternalSecret`'s `secretStoreRef.name` matches the `ClusterSecretStore`'s own
  `metadata.name` exactly.
- Live: a real Infisical secret planted under a real Application's `secretsPath`,
  confirming the resulting `app-secrets` Secret contains only the specific declared
  key/value, correctly renamed per `secretKey`, via the `infisical` provider (not the
  old `kubernetes` provider this replaced).
- End-to-end Slack check: a real pipeline run for an Application with `secrets:
  [{name: slack-webhook-url}]` and `notifications.slack.enabled: true` configured,
  confirming a real message lands in the real Slack channel via the Infisical-synced
  secret.
