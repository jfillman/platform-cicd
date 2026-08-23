# Release guardrails: adding and removing a gate

The release stage's governance checks (docs/release.md) are the platform's release
**guardrails** - independent, required GitHub Checks on every gitops-repo release PR.
This doc covers the mechanism that makes a gate a one-file (or two-file) addition rather
than a change scattered across half a dozen places, and the checklist for actually doing
that. See [governance-stubs.md](governance-stubs.md) for how a stub stays honestly a
stub, and [ADR-0003](adr/0003-governance-stubs.md) for why stubs are structurally loud
rather than a silent `exit 0` - this doc is the "how to add one" companion to that
decision, not a new one.

## The single source of truth

`charts/platform-cicd-catalog/values.yaml`'s `releaseGuardrails` list is the canonical
registry of every gate enforced on a release PR - `name`, a human `description`, and
`status` (`real` or `stub`, cosmetic only - see below). Two places render off it instead
of hardcoding the gate list:

- `catalog/tasks/detect-bypass-merge.yaml` - the break-glass Slack alert's "did every
  required check actually pass" loop.
- `catalog/tasks/open-release-pr.yaml` - the release PR body's governance-checks table.

Everything else about a gate - which Pipeline it runs, what it actually checks, whether
it posts a PR comment - is standard Tekton/PaC config, not driven by this list. Adding a
name to `releaseGuardrails` **alone does nothing**; the gate exists once its own
`.tekton/pull-request-<name>.yaml` onboarding template and Pipeline exist too (below).
Branch protection (which checks are actually *required* to merge) is a separate, manual
GitHub setting - see "Branch protection" below.

## Two shapes, depending on what the gate needs

**A. Independent stub or real check (the common case)** - most gates (sast, image-scan,
policy-check, sbom, itsm, qa, policy-validation) run in parallel off the same PR
webhook, with no dependency on each other's outcome:

- **Stub**: add one onboarding template file,
  `charts/platform-cicd-app/files/onboarding-templates/gitops-repo/pull-request-<name>.yaml`,
  pointing at the existing shared `governance-check` Pipeline with `gate-name: <name>`
  (copy `pull-request-itsm.yaml` as a starting point). That Pipeline already calls
  `governance-gate-stub` (loud "no real check implemented yet" logging + a
  `governance.stub=true` span + a `"stub"` result, never a silent pass) and posts a PR
  comment. **No new Pipeline or Task needed** - this is the whole change, plus the
  registry entry above.
- **Real**: once real logic exists, give the gate its own dedicated Pipeline (see
  `sbom-check.yaml` for the shape: one or more real Tasks, a `finally: comment-pr` block
  identical to every other gate's), and repoint that gate's onboarding template file at
  it instead of `governance-check`. Flip its `releaseGuardrails` entry to `status: real`.
  Nothing about the onboarding template file's *shape* changes, only the `pipelineRef`
  name and dropping `gate-name` (see `pull-request-sbom.yaml` vs. this doc's stub
  example for the before/after).

**B. A gate that depends on the others (currently just `image-promotion`)** - Tekton has
no cross-PipelineRun `runAfter` (every gate is its own independently PaC-triggered
PipelineRun off the same webhook, run in parallel - see `governance-check.yaml`'s own
header), so a gate that must run *after every other gate succeeds* needs its own
dedicated Pipeline that polls the GitHub Checks API for the rest. See
`image-promotion-check.yaml` and `catalog/tasks/wait-for-release-guardrails.yaml` - the
latter is generic (Helm-rendered off `releaseGuardrails`, minus the calling gate itself)
and reusable if a second such gate is ever needed.

## Current gates

| Gate | What it verifies | Status |
|---|---|---|
| `sast` | Static analysis (Semgrep) of the promoted commit's source | real |
| `image-scan` | Vulnerability scan (Trivy) of the promoted image | real |
| `policy-check` | Commit signature (gitsign) + SLSA provenance (Conforma) | real |
| `sbom` | Software bill of materials | real |
| `itsm` | ServiceNow Change Request | stub |
| `qa` | Test-completion verification | stub |
| `policy-validation` | Gatekeeper/Kyverno admission-policy validation of the rendered manifest | stub |
| `image-promotion` | Promotes the image from the dev registry to this env's upper registry - runs last, dependent on every gate above | stub |

`policy-check` and `policy-validation` are deliberately separate gates, not one - the
former is about the *commit*'s signer identity and the *image*'s provenance attestation
(docs/commit-signing.md, docs/provenance-policy.md), the latter is about the *rendered
manifest*'s compliance with cluster admission policy. Different failure modes, different
fixes, kept as independent required checks rather than folded together.

## Removing a gate

Delete its onboarding template file
(`charts/platform-cicd-app/files/onboarding-templates/gitops-repo/pull-request-<name>.yaml`)
and its `releaseGuardrails` entry. If it had a dedicated Pipeline/Task (a promoted-to-real
gate, or `image-promotion`'s Pipeline/Task), remove those too once nothing else
references them. Two things this does **not** do automatically:

- **Already-onboarded gitops repos** still have the old `.tekton/pull-request-<name>.yaml`
  file from a prior onboarding-resync - `deliver-onboarding-files.yaml` only ever adds
  missing files, it doesn't prune ones that disappeared from the template directory (a
  deliberate asymmetry - deleting a tenant's own customization was never the intent of an
  onboarding-resync PR). Remove the stale file from each gitops repo by hand (or via a
  one-off script) if the gate is really gone for good.
- **Branch protection** on the gitops repo's `main` still lists the old check name as
  required (see below) - a required check that no PR will ever produce again blocks every
  future release PR from merging until removed.

## Branch protection

Not IaC-managed by this platform (docs/release.md's own "Onboarding" section covers the
one-time per-repo setup) - `releaseGuardrails` and branch protection's required-status-
checks list are two independent settings that must be kept in sync **by hand**. Adding a
gate here without also adding it to branch protection means the check runs and reports,
but never actually blocks a merge. Removing a gate without removing it from branch
protection means every future release PR is permanently unmergeable (a required check
that will never run again). Neither mismatch is caught automatically - update both
together.
