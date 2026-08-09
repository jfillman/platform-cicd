# Application secrets (`secrets:`)

Lets an Application pull specific keys out of its own backend secret store into a
Kubernetes Secret its pipelines can mount - `slack-webhook-url` today, and open-ended
for whatever a future Task needs (SAST scan credentials was the second real case that
motivated building this generically instead of one-off per secret, same as
[secrets-management.md](secrets-management.md)'s `registry-credentials`).

## Where the backend store lives

Each Application's own backend secret store is a real Kubernetes Secret living in that
Application's **existing dev environment namespace** (`<type>-<app-name>-dev`) - no new
namespace convention, reusing infrastructure that already exists for every Application.
This is a deliberate, explicit choice (not an assumption this doc is guessing at): for
now, before a real external vault exists, a plain `kubectl create secret` in the dev
namespace is the backend, exactly the same "manual by design" pattern
[secrets-management.md](secrets-management.md) already uses for the shared
`platform-secrets` namespace.

```yaml
appSecretStore:
  secretName: app-secrets    # the ONE backend Secret object in <type>-<app-name>-dev
```

That's the only per-Application value the **app chart** needs - it names the backend
Secret *object*, not its namespace (the namespace is always `<type>-<app-name>-dev`, a
fixed formula, not configurable per Application).

## Why a ClusterSecretStore per Application, defined in the control-plane chart

[secrets-management.md](secrets-management.md)'s `platform-secrets` `ClusterSecretStore`
is correct for `registry-credentials` because every Application genuinely shares one
backend (one `ghcr.io/jfillman` registry) - one `ClusterSecretStore`, one fixed
`remoteNamespace`, cluster-wide. An Application's own secrets need a *different*
`remoteNamespace` per Application (`<type>-<app-name>-dev` varies by Application) - so
this uses one `ClusterSecretStore` **per Application** instead
(`ClusterSecretStore` is what the user asked for here, not a namespaced `SecretStore` -
functionally similar, but cluster-scoped, matching the shape `platform-secrets` already
uses).

These are rendered by the **control-plane chart**, not the per-Application app chart -
`charts/platform-cicd-control-plane/templates/secretstore/app-secret-stores.yaml`,
looping over a new `appSecretStores` values list:

```yaml
# charts/platform-cicd-control-plane/values.yaml
appSecretStores:
  - type: app
    appName: cicd-flow-test-app
```

Each entry renders one `ClusterSecretStore` named `<type>-<appName>-secret-store`,
`remoteNamespace: <type>-<appName>-dev`. Adding a new Application here (and re-running
`helm upgrade` on the control-plane chart) is a deliberate, manual, one-time-per-
Application step - the same kind of manual step `platform-secrets` onboarding already
is, not a new class of toil.

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

No new RBAC needed either way: ESO's own installed `external-secrets-controller`
`ClusterRole` already grants `get`/`list`/`watch` on Secrets with no namespace
restriction (confirmed live via `kubectl get clusterrole external-secrets-controller -o
yaml`) - a new `remoteNamespace` per entry costs nothing extra.

## `cicd.yaml`

```yaml
secrets:
  - name: slack-webhook-url      # key in the resulting app-secrets Kubernetes Secret
  - name: sast-scan-token
    key: sast-creds-token        # only needed when the backend key is named differently
```

Each entry becomes one `data[]` entry in a single per-Application `ExternalSecret`
(`app-secrets-external-secret.yaml`), all landing in **one** target Secret
(`app-secrets`) - not one Secret per declared entry. A consuming Task always mounts the
same Secret name regardless of how many keys an Application has declared; adding a new
purpose is a `cicd.yaml` edit only, never a new volume/volumeMount anywhere. `key`
defaults to `name` - set it only when the name you want exposed as differs from the
name it actually has in the backend store.

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
what `notify-slack.yaml` already does for `slack-webhook-url`, now sourced from
`app-secrets` instead of a hand-created, per-Application Secret.

## `slack-webhook-url`: what changed

Previously (see [notifications.md](notifications.md)'s "The bug this fixes"): a manual,
per-Application `kubectl create secret generic slack-webhook-url ...`, deliberately kept
outside ESO - "not a full ESO SecretStore pipeline for one demo webhook." That tradeoff
made sense with exactly one consumer. It stopped making sense once a second real
consumer (SAST creds) needed the identical mechanism - building the general pipeline
once now covers both, and every future case, for the same cost.

To enable Slack notifications for an Application today:

1. Add the Application to control-plane's `appSecretStores` list (one-time, if not
   already there) and `helm upgrade` that chart.
2. Declare the secret in the Application's own `cicd.yaml`:
   ```yaml
   secrets:
     - name: slack-webhook-url
   notifications:
     slack:
       enabled: true
       channel: "#your-channel"
   ```
3. Create/update the Application's backend Secret in its own dev namespace, with a
   `slack-webhook-url` key holding a real Slack incoming-webhook URL:
   ```
   kubectl create secret generic app-secrets -n <type>-<app-name>-dev \
     --from-literal=slack-webhook-url=<your real Slack incoming-webhook URL> \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
   (`--dry-run=client -o yaml | kubectl apply -f -` rather than a bare `kubectl create`
   so re-running this to add a second key, e.g. `sast-scan-token` later, updates the
   same Secret object instead of erroring on AlreadyExists.)

Nothing else to apply - `notify-slack.yaml`'s volume mount is already wired into every
pipeline via the existing, unconditional `notify` `finally` task.

## Verification

- `helm template`/`helm lint` both the control-plane chart (with a real
  `appSecretStores` entry) and the app chart (with and without `secrets:` set),
  confirming the `ClusterSecretStore`/`ExternalSecret` render correctly, the
  `ExternalSecret`'s `secretStoreRef.name` matches the `ClusterSecretStore`'s own
  `metadata.name` exactly, and the `ExternalSecret` only renders when `secrets:` is
  non-empty.
- ESO's `kubernetes` provider `data[].remoteRef.property` (extracting ONE key from a
  named remote Secret, as opposed to `registry-credentials`' whole-secret `dataFrom.
  extract`) was verified against the real cluster, not assumed from ESO's docs: a real
  backend Secret with multiple keys was created in a real Application's dev namespace,
  the matching `ClusterSecretStore`/`ExternalSecret` deployed, and the resulting target
  `app-secrets` Secret confirmed to contain only the specific declared key/value,
  correctly renamed per `secretKey`.
- RBAC check: confirmed live (`kubectl get clusterrole external-secrets-controller -o
  yaml`) that ESO's installed ClusterRole already has unrestricted Secret access before
  claiming "no new RBAC needed" rather than assuming it.
- End-to-end Slack check: a real pipeline run for an Application with `secrets:
  [{name: slack-webhook-url}]` and `notifications.slack.enabled: true` configured,
  confirming a real message lands in the real Slack channel via the ESO-synced secret
  (not the old manually-created one).
