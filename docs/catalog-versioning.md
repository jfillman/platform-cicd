# Catalog versioning, testing, and safe deployment

Before Phase 3 item 7, the shared catalog (`catalog/tasks|pipelines|stepactions`, now
`charts/platform-cicd-catalog`) had zero versioning: every catalog Pipeline resolves its
Tasks via Tekton's `resolver: cluster` by bare name against whatever happened to be
`kubectl apply`'d into the `platform-catalog` namespace at that moment - no git tags, no
CI, no staging, no rollback path. Given every real tenant pipeline run resolves the
catalog live, a bad edit took effect for every tenant immediately, with no way back short
of hand-reverting and re-applying.

## What changed: the catalog is now a real Helm release

`charts/platform-cicd-catalog` wraps the same Task/Pipeline/StepAction YAML that always
lived under `catalog/` (a "nearly free" conversion - every file was already flat,
unparameterized, valid standalone YAML). Versioning comes from `Chart.yaml`'s own
`version:` field plus `helm history`/`helm rollback` - free, no new infrastructure:

```
helm rollback platform-cicd-catalog -n platform-catalog       # revert to the previous release
helm rollback platform-cicd-catalog 3 -n platform-catalog     # revert to a specific revision
helm history platform-cicd-catalog -n platform-catalog        # see what's been deployed, when
```

This is **Option A**: one live copy in `platform-catalog`, shared by every tenant - a
rollback affects everyone at once, there's no per-tenant pinning. That's a real
limitation, accepted deliberately for now (see "Option B" below for the alternative and
why it's not built yet).

## Testing a change before it reaches every tenant

Since the chart needs zero real templating, a **second install of the same chart into a
second namespace** gives a genuine, live staging target with zero OCI-bundle machinery:

```
hack/promote-catalog.sh canary    # helm upgrade --install into platform-catalog-canary
```

Point one dedicated, always-on canary tenant's `platformIdentity.catalogNamespace` (see
the tenant chart's `values.yaml`) at `platform-catalog-canary` instead of the default
`platform-catalog`, and run a real build→test→deploy through it. Once you're confident:

```
hack/promote-catalog.sh promote   # helm upgrade --install into platform-catalog (prod)
```

## What CI actually checks (and what it can't)

`.github/workflows/catalog-ci.yaml` runs on every PR touching the catalog chart:
`helm lint`, a full `helm template` render (catches YAML/Go-template syntax errors - the
most common real mistake when hand-editing Tekton YAML, including the PaC-template-
variable-collision class of bug hit live while building this chart - see that file's own
`{{ repo_url }}` escaping note), and a structural sanity check (every rendered resource
has a name, an expected `kind`, no stray unrendered template syntax).

What CI **cannot** do: `kind-observe` is a local cluster on the user's own machine with
no public endpoint, so GitHub-hosted runners can't reach it for a real
`kubectl apply --dry-run=server` or an actual canary pipeline run. That verification is
real and still required before promoting - it just runs locally, via
`hack/promote-catalog.sh`, where real cluster access exists. Don't treat a green CI run
alone as "safe to promote" - it means the YAML is well-formed, not that a real pipeline
still works.

## Option B: Tekton bundle resolver (target state, not built yet)

Tekton's own idiomatic mechanism for exactly this problem is the **bundle resolver**
(OCI-packaged, tag-versioned Task/Pipeline bundles) - already proven working in this
codebase for `git-clone` via the Hub resolver, which is bundle-backed under the hood.
It gives genuine per-tenant/per-pipeline version pinning (each `.tekton/*.yaml`
references an explicit `bundle: ghcr.io/.../platform-catalog:v1.2.0`), and staging
becomes as simple as a different OCI tag rather than a whole second namespace.

This isn't just lower priority than Option A - it's **sequence-blocked**. Migrating every
onboarding-template `.tekton/*.yaml`'s resolver shape (`cluster`+namespace →
`bundle`+OCI ref) across every already-onboarded tenant is exactly the re-sync/staleness
problem [onboarding.md](onboarding.md#keeping-onboarding-boilerplate-in-sync) solves -
attempting B before that mechanism existed would mean hand-editing every tenant's
boilerplate again, reproducing the manual-toil problem this whole effort exists to kill.
Now that the re-sync mechanism exists, Option B is a real, buildable next step - not
attempted in this pass.
