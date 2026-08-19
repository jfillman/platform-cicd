# ADR-0005: Per-cluster ArgoCD instances, event-driven outcome reporting

## Context

Only one cluster needs to run the full Tekton/PaC/broker control plane (the dev
cluster); staging/prod-tier clusters just need to receive releases. The design has to
scale to *many* upper clusters over time (multi-region/multi-tenant-cluster), not just
one, all reporting back to the same dev cluster.

## Decision

Each additional cluster gets its own ArgoCD instance watching the same gitops repo,
rather than the dev cluster's ArgoCD being extended with remote-cluster credentials to
manage it. A single ArgoCD instance holding a remote-cluster credential is itself a
path from dev into prod - the same blast-radius problem this platform's whole RBAC
model exists to avoid, just relocated into ArgoCD's control plane instead of a Tekton
Task.

Outcomes flow back to dev as an *event*, not a push: ArgoCD Notifications on the
upstream cluster, configured with a custom webhook service, translates a
sync-succeeded/failed trigger into a CDEvent-shaped payload POSTed to dev's broker,
authenticated with a shared secret per upstream cluster (not HMAC - ArgoCD
Notifications' webhook service can only send static headers). A relay service in
front of the existing broker consumes it, rather than modifying the broker's own
TokenReview path. Cluster identity is a first-class field in this payload/auth scheme
from the start, not assumed to be a single implicit "prod."

## Consequences

- Dev never holds a credential for staging/prod, at any point - verified live, not
  assumed.
- Adding a new upper cluster is "stand up its own ArgoCD, register a webhook secret,"
  not a change to the dev cluster's own credentials or trust boundary.
- The DORA exporter gained a second, HTTP-driven input path (fed by the relay) instead
  of replacing its original same-cluster CDEvents informer - both paths coexist.
