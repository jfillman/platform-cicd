# Application secrets (`secrets:`)

Lets an Application pull specific keys out of its own backend secret store into a
Kubernetes Secret its pipelines can mount - `slack-webhook-url` today, and open-ended
for whatever a future Task needs (SAST scan credentials was the second real case that
motivated building this generically instead of one-off per secret).

## Where the backend store lives

**2026-08-19: every Application secret comes from that Application's own idp-managed
Infisical project** - `<appName>-<devClusterName>` (`devClusterName` from
control-plane's own values, today always `kind-dev`), the exact same project
idp-service-catalog's `NodeJSApplication` XR provisions and `idp-application`'s own
`external-secret.yaml`/`notify-external-secret.yaml` already read from. Not a
platform-cicd-owned project, not path-scoped under one - an Application's secrets are
that Application's own, managed once, in the one place idp already gives every
onboarded app.

**This corrects an earlier, wrong design** (shipped and reverted the same day): the
first pass at this migration created a platform-cicd-owned `platform-cicd-kind-dev`
Infisical project and expected every Application's secrets - including
`slack-webhook-url`, already managed in the app's own project for
`idp-application`'s AI-triage notifications - to be planted there too, under a
`/<type>/<appName>/` path. That meant two copies of the same credential in two
different places for anything idp-application also needed. Fixed by pointing the whole
mechanism at the app's own project instead - see `app-secret-stores.yaml`'s own header
for the full story.

Before that, this worked off each Application's own `<type>-<app-name>-dev` namespace,
treated as an ad hoc vault (a real `Secret` created there by hand) - CI/deploy
infrastructure doing double duty as a secret backend. That's gone too.

```yaml
secrets:
  - name: slack-webhook-url      # key in the resulting app-secrets Kubernetes Secret,
                                   # and the secret's own name in this app's Infisical
                                   # project
```

**A real, accepted coupling**: an Application's CI secrets now require that Application
to have been onboarded through idp's `NodeJSApplication` XR (which is what actually
provisions `<appName>-<devClusterName>`) - a platform-cicd tenant that predates or
skips idp onboarding has no such project, so its `secrets:` entries simply stay
not-ready (see "Why a ClusterSecretStore per Application" below for the graceful-degrade
shape this takes, not a hard pipeline failure).

No per-Application app-chart value names the backend any more (the old
`appSecretStore.secretName` field is gone) - the backend is entirely determined by
`platformIdentity.type`/`.appName` plus control-plane's `devClusterName`, computed the
same deterministic way idp's own Composition computes its project slug.

## Why a ClusterSecretStore per Application, defined in the control-plane chart

Even though the backend is idp's own project, platform-cicd still renders its own
`ClusterSecretStore` per Application rather than having the app chart's `ExternalSecret`
reference idp's object (e.g. `checkout-api-kind-dev`) directly - a deliberate
indirection: platform-cicd's own naming convention (`<type>-<appName>-secret-store`)
stays stable and independent of idp's internal naming, and platform-cicd's chart never
has to assume idp's naming scheme won't change.

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
`provider.infisical` pointed at `<appName>-<devClusterName>`'s project/environment/
credentials - mirroring that app's own idp-provisioned `ClusterSecretStore` field for
field (confirmed live against a real one, e.g. checkout-api's own
`checkout-api-kind-dev` store), not looked up via any live cross-reference to idp's own
object. Adding a new Application here (and pushing to `main` - the control-plane
chart's own ArgoCD Application has automated selfHeal sync, no manual `helm upgrade`
needed) is a deliberate, manual, one-time-per-Application step.

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
mounts a missing key differently than an unconfigured one, see below). Same graceful
degrade if the Application hasn't been onboarded through idp yet either - the store
just can't validate until it has.

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

## Enabling Slack notifications for an Application

1. Onboard the Application through idp's `NodeJSApplication` XR first, if it hasn't
   been already - that's what actually provisions `<appName>-kind-dev`, the Infisical
   project everything below reads from.
2. Add the Application to control-plane's `appSecretStores` list (one-time, if not
   already there) and push to `main` - automated selfHeal picks it up, no manual `helm
   upgrade` needed.
3. Declare the secret in the Application's own `cicd.yaml`:
   ```yaml
   secrets:
     - name: slack-webhook-url
   notifications:
     slack:
       enabled: true
       channel: "#your-channel"
   ```
4. Plant `slack-webhook-url` in the Application's own Infisical project (`shared`
   environment, root path) - via the Infisical UI/API, never through this chart or
   committed to this repo. If `idp-application`'s own AI-triage Slack notifications are
   already enabled for this app, this value already exists - nothing more to do.

Nothing else to apply - `notify-slack.yaml`'s volume mount is already wired into every
pipeline via the existing, unconditional `notify` `finally` task.

## Verification

- `helm template`/`helm lint` both the control-plane chart (with a real
  `appSecretStores` entry) and the app chart (with and without `secrets:` set),
  confirming the `ClusterSecretStore`/`ExternalSecret` render correctly and the
  `ExternalSecret`'s `secretStoreRef.name` matches the `ClusterSecretStore`'s own
  `metadata.name` exactly.
- Live: control-plane's own `<type>-<appName>-secret-store` confirmed to validate
  (`kubectl get clustersecretstore <name> -o jsonpath='{.status.conditions}'`) against
  a real app's idp-managed project, and the resulting `app-secrets` Secret confirmed to
  hold the same value already live in that app's own project - not a second, drifted
  copy.
- End-to-end Slack check: a real pipeline run for an Application with `secrets:
  [{name: slack-webhook-url}]` and `notifications.slack.enabled: true` configured,
  confirming a real message lands in the real Slack channel via the Infisical-synced
  secret.
