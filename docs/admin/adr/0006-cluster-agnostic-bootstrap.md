# ADR-0006: Cluster-agnostic bootstrap, no cluster state in the app repo

## Context

Every new cluster needs its own irreducible per-cluster material (its own API server
root CA, its own independently-generated Fulcio signing root - trust roots are
deliberately never shared between clusters). Hand-typing this per cluster (openssl run
by hand, certs copy-pasted into a values file) doesn't scale past one or two clusters
and risks a copy-paste trust-root leak between them. Committing that material inside
`platform-cicd`'s own repo also means the "reusable application" repo accumulates
cluster-specific secrets and identity over time - `platform-cicd` should be
installable standalone on any cluster, including ones that don't exist yet.

## Decision

`hack/generate-cluster-values.sh` reads a target cluster's own API server CA live and
generates a fresh Fulcio root for it, refusing to regenerate the Fulcio root
accidentally (`FORCE=1` required) since that would invalidate every image already
signed under the old one. Its output is a values file written to wherever the caller
points it - by default, `platform-cicd`'s own `hack/` (for an ad-hoc/imperative
install with no gitops repo yet), but normally the target cluster's own
`gitops-cluster-<name>` repo, next to the ArgoCD `Application` that consumes it via a
multi-source `$ref`. Chart-level values that used to be hand-typed per cluster
(tenant-repo URL, ApplicationSet name) now derive from a single `clusterName` value by
convention instead.

## Consequences

- `platform-cicd` carries zero cluster-specific secrets or identity in its own repo -
  standing up cluster N is "run the generator, commit its output to that cluster's own
  config repo," not "hand-edit a new file inside platform-cicd and hope nothing
  collides with another cluster's values."
- A new cluster's onboarding is close to "fill in a small parameter set" rather than
  "copy the last cluster's file and edit every field by hand."
- One documented, deliberate exception: a cluster bootstrapped before this convention
  existed keeps its historical values file as pinned overrides rather than being
  retrofitted to match - see that file's own header for why.
