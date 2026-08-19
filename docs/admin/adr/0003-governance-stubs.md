# ADR-0003: Governance gates as explicit, structurally-loud extension points

## Context

Real quality/security gates (SAST, image scanning, policy-as-code, SBOM attestation)
take real time to build correctly. A platform that ships governance-gate *names*
without real enforcement behind them is dangerous if that gap is invisible - a gate
that always silently passes is worse than no gate at all, because it's trusted.

## Decision

Governance gates are built as explicit extension points from day one, with stub-ness
made structurally loud rather than hidden in code comments: a
`governance.stub=true`-equivalent result/span attribute, rendered visually distinct
in Grafana wherever a gate's outcome is shown. A stub is never reported as if it were
a real check. Each gate (SAST, image scan, policy check, SBOM) is implemented and
promoted to real enforcement independently as it's built - see
[governance-stubs.md](../governance-stubs.md) for current status of each.

## Consequences

- Anyone looking at a pipeline's governance results can immediately tell a stub from
  a real gate - no silent governance theater.
- Gates can be added/promoted incrementally without a big-bang cutover - each one's
  stub→real transition is independent.
- On a `release`, each real gate reports as its own independent, required GitHub
  status check against the gitops PR, gated by branch protection - not a single
  aggregate "governance passed" bit.
