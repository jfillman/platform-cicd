# Secrets management

External Secrets Operator (ESO) is platform infrastructure, not just a bootstrap-time
install alongside Tekton/PaC/kube-prometheus-stack. Every chart in this platform consumes
secret material via a real `ExternalSecret`, not a hand-applied raw `Secret` - see
`charts/platform-cicd-tenant/templates/identity/registry-credentials-external-secret.yaml`
for the concrete example.

## The bridge: ESO's own `kubernetes` provider

ESO was installed early in this platform's life but had **zero configured backends**
until Phase 3 item 7 (confirmed live: `kubectl get externalsecret,clustersecretstore -A`
returned nothing for most of this platform's build-out). Standing up a real external
vault (HashiCorp Vault, a cloud secrets manager) is a real, separately-decided
infrastructure choice - not made here. The pragmatic bridge, installed by the
control-plane chart:

```
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: platform-secret-store
spec:
  provider:
    kubernetes:
      remoteNamespace: platform-secrets
      ...
```

ESO's built-in `kubernetes` provider mirrors real `Secret`s from one dedicated,
narrowly-RBAC'd namespace (`platform-secrets`) into wherever an `ExternalSecret`
references this store. **The user still runs `kubectl create secret` themselves, exactly
as before** - this changes nothing about who creates real credential material or how,
only where it needs to live (one shared namespace instead of scattered `kubectl create
secret` invocations per-tenant) and how every other chart consumes it (a real,
declarative `ExternalSecret` instead of assuming a Secret already exists). No credential
is ever pasted through chat, committed to this repo, or embedded in any chart.

## Populating it (one-time, manual, by design)

```
kubectl create namespace platform-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry registry-credentials -n platform-secrets \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
```

Every tenant's `registry-credentials` `ExternalSecret` (rendered by the tenant chart)
syncs from this one source - since every tenant currently pushes to the same
`ghcr.io/jfillman` registry, one shared credential is correct, not a limitation. A tenant
needing a genuinely different registry credential would get its own key in
`platform-secrets` and its own `ExternalSecret` referencing that key - not built now,
since no tenant needs it yet.

## What this deliberately is not

Not a real vault: `platform-secrets` Secrets are ordinary Kubernetes Secrets (etcd-backed,
base64-encoded, not encrypted-at-rest beyond whatever the cluster itself provides) - the
same trust level every credential in this platform already had, just consumed through a
better interface. Not audited/rotated automatically: ESO's `refreshInterval` re-syncs on
a timer, it doesn't rotate the underlying credential itself.

## The real future step: community Infisical, via Dream IDP

The user's own stated direction is community Infisical as the eventual secrets backend,
once [Dream IDP](../README.md) (the larger Crossplane+Backstage+MCP project this platform
is one component of) exists - explicitly **not** built as part of this platform. Because
every chart here references the store by name/kind (`secretStore.name`/`secretStore.kind`
values, not a hardcoded provider type), swapping the `ClusterSecretStore`'s `spec.provider`
from `kubernetes` to `infisical` later is a values change in one file
(`charts/platform-cicd-control-plane/values.yaml`), not a rewrite of every chart that
consumes a secret.
