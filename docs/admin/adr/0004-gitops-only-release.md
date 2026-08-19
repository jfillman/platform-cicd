# ADR-0004: GitOps-only release promotion

## Context

Promoting a build to a real, human-facing environment needs a human-reviewable gate
and no path for a compromised or buggy pipeline component to mutate that environment
directly.

## Decision

The `release` stage never touches a target cluster directly. It opens a pull request
against a dedicated `gitops-<app-name>` repo, carrying the exact image digest that
already passed `test`/`deploy` (never rebuilt for release). Governance checks
(ADR-0003) report as independent, required GitHub status checks on that PR; branch
protection requires human review. ArgoCD's own sync against that repo is the *only*
thing that ever mutates the target cluster.

## Consequences

- A compromised or misconfigured release pipeline can, at worst, open a bad PR - it
  cannot itself deploy anything.
- Promotion is auditable as ordinary git history: every release is a real, reviewed
  commit, not a live `kubectl`/`helm` action with no durable record.
- This is strictly slower than a direct-deploy path by design - see
  [features.md](../../user/features.md#two-very-different-deploy-paths-on-purpose)
  for why `deploy` (fast, ungated, dev-only) and `release` (slow, governed) are
  deliberately built to different standards rather than unified into one path.
