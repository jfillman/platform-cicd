# cicd.yaml reference

`cicd.yaml` at an app repo's root is the **only** file a developer edits to control
their pipelines. There is no Tekton YAML to write, read, or understand - the platform
owns everything under `.tekton/` (pure boilerplate, generated at onboarding, see
[onboarding.md](onboarding.md)) and the shared catalog (`catalog/`).

See [examples/cicd.yaml](examples/cicd.yaml) for a complete example and
[../schemas/cicd.schema.json](../schemas/cicd.schema.json) for the authoritative schema.

## Design rules this file follows

- **Read fresh, every run, from the triggering commit.** `validate-cicd-config` (always
  the first Task in every Pipeline) reads `cicd.yaml` straight out of the cloned
  workspace and validates it on the spot. There is deliberately no ConfigMap sync, no
  cache, no second copy anywhere - a `cicd.yaml` change takes effect on the very next
  push, full stop. An earlier draft of this design had a "sync config to a ConfigMap"
  path; it was cut because it's a second subsystem duplicating what the git webhook
  already gives for free, and because it means edits take effect on some other
  controller's schedule instead of immediately - see the plan's Context section for why
  that mattered enough to redesign.
- **Fixed superset DAG, not arbitrary graphs.** The `pipeline:` list toggles and orders
  a known, finite stage set (`build`, `test`, `deploy`, `release`) via `when:`-guarded
  Tasks in the shared catalog Pipelines. It cannot express an arbitrary DAG - that would
  require compiling a bespoke `Pipeline` per app from `cicd.yaml`, which is a
  meaningfully heavier engineering commitment (a real compiler: validation, versioning
  of generated Pipelines) than is justified until there's real evidence apps need it.
- **`governance` toggles are honest about being stubs.** Setting `governance.sast: true`
  wires a `governance-gate-stub` Task into your pipeline shape - it does not run a real
  SAST scan yet. See [governance-stubs.md](governance-stubs.md). This is deliberate: the
  old platform had gates that looked identical whether they were real or `exit 0`
  one-liners. This one doesn't let that ambiguity exist.

## Two build strategies: `build.script`, or a multi-stage Dockerfile

`build.script` (e.g. `./build.sh`) is **optional**, not required. Two ways to structure
a build, pick whichever fits:

- **Script + thin Dockerfile** (the reference shape - see
  [examples/cicd.yaml](examples/cicd.yaml)): `build.script` does the actual build (`npm
  ci && npm run build`, `mvn package`, ...) inside the resolved `build.agent` image, and
  `build.dockerfile` becomes a thin packaging step that just copies the already-built
  artifacts. This runs as its own Tekton Task (`build-source`), concurrently with unit
  tests - see [tracing.md](tracing.md)/the build Pipeline's own DAG comments for why that's
  safe (they don't share build output).
- **Everything in a multi-stage Dockerfile**: omit `build.script` entirely and do the
  whole build inside `build.dockerfile` (`FROM ... AS builder` / `RUN npm ci && npm run
  build` / `COPY --from=builder`). The `build-source` Task is skipped entirely (Tekton's
  `when:` clause, driven by `validate-cicd-config`'s `has-build-script` result) and kaniko
  builds the Dockerfile directly. Build caching in this path comes from kaniko's own layer
  cache (confirmed live - kaniko logs `Returning cached image manifest` on unchanged
  layers, a real effect of `--cache=true`, not just the flag being present), not
  `build.cache` below - order your Dockerfile's `COPY package*.json` / `RUN npm ci` (or
  the Maven/`pom.xml` equivalent) *before* copying the rest of the source, standard
  Docker layer-caching practice, or the cache invalidates on every source change
  regardless of whether dependencies changed.

`build.agent` is required either way - unit tests always run inside it, independent of
which build strategy you pick.

## Build dependency caching (`build.cache`)

Only applies to the `build.script` path above - the multi-stage-Dockerfile path caches
via kaniko's own layers instead (see above). Opt in with:

```yaml
build:
  agent: nodejs-20
  script: ./build.sh
  cache:
    enabled: true
    size: small   # small=1Gi, medium=2.5Gi, large=5Gi, xlarge=8Gi - default small
```

No `type` field - it's derived from `build.agent`'s prefix (`nodejs-*` -> npm, `openjdk-*`
-> Maven), not a second, separately-declarable value that could disagree with `agent`.
Agents without cache support yet (`python-*`, `go-1.22`) treat `enabled: true` as a no-op
(logged, not an error).

`size` is a t-shirt size (same dictionary as the old `cd-pipelines-user` Helm chart's
`buildSpec.cacheSize`, reused as-is: small=1Gi, medium=2.5Gi, large=5Gi, xlarge=8Gi),
picked per-app since different apps have genuinely different dependency-tree sizes -
default `small` if omitted. **Not resizable live**: kind-observe's default `standard`
StorageClass has `allowVolumeExpansion: false` (confirmed via `kubectl get
storageclass`), so changing this after onboarding means deleting and recreating the PVC
(losing its cached content, not otherwise harmful), not a transparent resize.

What's actually cached is the build tool's own *download* cache (npm's tarball cache via
`NPM_CONFIG_CACHE`, Maven's local repository via `-Dmaven.repo.local`) - not
`node_modules`/`target` directly. `npm ci` in particular deletes and rebuilds
`node_modules` from scratch on every run by design, so caching that directory would do
nothing; what actually avoids re-downloading is the tool's own cache, backed here by a
real, persistent, **per-app** PVC (`build-cache-<app-name>`, provisioned at onboarding -
see `charts/platform-cicd-app/templates/env/build-cache-pvc.yaml`) that survives across
runs, unlike the ephemeral per-run `source` workspace. Per-app rather than shared across
an Application's apps specifically so `size` above can vary per app.

The cache is keyed by a hash of the relevant lockfile (`package-lock.json` for npm,
`pom.xml` for Maven), scoped under `<cache-type>/<hash>` on the PVC - a dependency
change produces a new hash and therefore a fresh, uncontaminated cache subdirectory,
rather than silently serving stale packages. Verified live: a rebuild with an unchanged
lockfile measurably reused the existing download cache (npm's own reported install time
dropped from 584ms to 317ms); a lockfile content change produced a new cache key and
fell back to a full, uncached download (720ms), with the old key's cache left untouched
alongside it.

**Initialization**: there's no seeding step. The PVC is created empty (a manual
`kubectl apply` of the onboarding template today, same maturity level as
`registry-credentials`); cache *content* is populated lazily by whichever build first
hits a given `<cache-type>/<hash>` key - exactly the miss-then-hit sequence verified
above. Nothing pre-warms it.

**Concurrent builds** (real, expected usage on this platform - multiple feature
branches, or PR-triggered ephemeral-env builds, building the same app at the same time)
share this same per-app cache, since it isn't scoped per-branch/per-PipelineRun. npm and
Maven behave differently here, and the platform treats them differently as a result:
npm's own cache store is content-addressable and explicitly built for safe concurrent
access from multiple processes - no extra handling needed. Maven's local repository is
not - concurrent `mvn` processes writing to the same local repo is a well-documented
corruption risk - so `build-source.yaml` wraps the Maven case in a plain, portable
mkdir-based lock (no extra binary dependency on a generic upstream agent image) that
serializes concurrent builds landing on the *same* cache key (which only happens when
they share the identical `pom.xml`, so they'd resolve the same dependencies anyway);
different keys never contend, so this doesn't add contention for the common case of
different branches touching different dependencies.

Implementation note for anyone touching `build-source.yaml`: this cache is mounted as a
plain Kubernetes `volumes:`/`volumeMounts:` entry, not a Tekton *workspace* - a
workspace-bound PVC here collides with Tekton's Affinity Assistant (active because
`unit-test` and `build-source` share the PVC-backed `source` workspace concurrently,
Phase 3 item 8.1), which only supports one PVC-backed workspace per TaskRun pod
(confirmed live: `[User error] more than one PersistentVolumeClaim is bound`). See
`build-source.yaml`'s own header comment for the full explanation.

## A real bug that made `enabled: false` silently ineffective

`build.unitTest.enabled` and `test.enabled` both used to be read via `jq -r '.path.enabled
// true'` - a genuine, previously-undiscovered bug: jq's `//` alternative operator treats
`false` the same as `null`/missing and falls through to the right-hand default, so an
explicit `enabled: false` was silently overridden back to `"true"`. **No Application had ever
actually been able to disable unit tests or the integration-test stage via `cicd.yaml`**
until this was found and fixed (`run-tests.yaml`/`run-integration-tests.yaml`, now
`jq -r 'if .path.enabled == false then "false" else "true" end'`). Found as a side effect
of building the same fix for `notifications.slack.scanResults` below, then confirmed via
a direct `jq` test (`echo '{"test":{"enabled":false}}' | jq -r '.test.enabled // true'`
prints `true`) before scanning the rest of the catalog for the same pattern. Verified
live afterward: `unitTest.enabled: false` now genuinely skips the test command
(`unit tests disabled in cicd.yaml, skipping`, not an actual test run).

Anywhere else in this catalog that needs "default true unless explicitly false" should
use the `if ... == false then ... else ... end` form, not `// true` - `// false` is fine
as-is (both sides collapse to the same falsy result either way, so there's nothing for
the bug to hide behind).

## Staleness of the platform-generated boilerplate - resolved, Phase 3 item 7

`cicd.yaml` itself never goes stale (see above), and as of Phase 3 item 7 neither does
the boilerplate `.tekton/` generates into an app/gitops repo: `push.yaml`/
`pull-request.yaml` (and the gitops repo's 5 governance-check files) reference the shared
catalog by Pipeline name and param list, and used to need a hand re-sync whenever the
catalog changed - now automated via `onboarding-templates/.tekton/onboarding-resync.yaml`
(fires on any `cicd.yaml` change) + `charts/platform-cicd-catalog/templates/tasks/deliver-onboarding-files.yaml` (opens
a PR with regenerated files, skipping the PR entirely when nothing actually changed) -
see [onboarding.md](onboarding.md#keeping-onboarding-boilerplate-in-sync). Re-running
that same Pipeline manually is also how a platform-side onboarding-template change gets
pushed out to already-onboarded repos, not just a app-side `cicd.yaml` edit.

## Multi-stage pipeline flows

The `pipelines:` field enables declarative control of multi-stage, self-chaining pipelines. Rather than configuring individual legacy triggers, teams declare named flows with a root trigger source and a sequence of stages. Each flow runs the corresponding catalog Pipeline (`build`, `test`, `deploy`, `release`) - no custom Pipelines or DAG configuration needed.

**Editing `pipelines:` has two independent effects, not one** - easy to forget, confirmed
live as a real source of confusion while building this: changing `cicd.yaml`'s `pipelines:`
section and pushing it does NOT, by itself, change which event-chained Triggers exist in
the cluster. That only happens via `helm upgrade` of the app chart (`charts/
platform-cicd-app`) picking up the new `cicd.yaml` as its values file - see
[onboarding.md](onboarding.md) step 5. The git push side (delivering the updated
git-rooted `.tekton/*.yaml` PipelineRun definitions via onboarding-resync) is fully
automatic; the cluster-side Trigger/TriggerBinding/TriggerTemplate objects are not -
re-run `helm upgrade` yourself after any `pipelines:` edit that adds, removes, or
reorders event-chained steps, or the new stages simply won't fire (the git-rooted root
stage still will, since that part IS automatic, which is what makes this easy to miss).

### How flows work

**Trigger sources**: The root trigger can be `git` (pushed webhook from Pipelines-as-Code, for build/release stages) or `event` (CDEvent broker, for downstream chaining). Subsequent stages are always event-chained: each stage's completion emits a CDEvent that the next stage listens for.

**Event chaining rules** - keyed by whichever stage the step actually follows, not by
the step's own identity, so any of these pairings works in any combination (confirmed
live, including the less obvious `release` → `test` case):
- `build` → next: triggered by `artifact.published` (image built and pushed)
- `test` → next: triggered by `testcaserun.finished` with `outcome: Succeeded` (`test`
  is the one stage whose domain event fires unconditionally, pass or fail - every other
  stage's event is already gated at the source, so only this transition needs the
  outcome check)
- `deploy` → next: triggered by `service.deployed`
- `release` → next: triggered by `change.created`

**Tracing across stages**: Each flow gets a `chain-id` and OpenTelemetry `traceparent` at the root stage, threaded through all subsequent stages via CDEvent payloads. The flow-root span covers the entire automated pipeline execution (all stages' durations), not including human review/merge time.

### Flow examples

**Example 1: Simple linear flow (build → test → deploy)**

Triggered on every push to main branch, runs build, test, and deploy to dev environment automatically:

```yaml
apiVersion: platform/v1
kind: PipelineConfig
build:
  agent: nodejs-20
  script: ./build.sh
  dockerfile: ./Dockerfile

pipelines:
  standard-dev:
    trigger:
      source: git
      event: push
      branch: main
    steps:
      - stage: build
      - stage: test
      - stage: deploy
        env: dev
```

**Example 2: Release-only flow (git-rooted)**

Release can be git-triggered independently for manual release coordination - on a tag
push, not a GitHub Release object. **There is deliberately no `event: release.created`
option** - confirmed live that Pipelines-as-Code has no support for GitHub's `release`
webhook at all, at any version (a real delivery came back HTTP 200 with body
`{"message":"skipping non supported event"}`, filtered out before PaC's own annotation
matching ever runs - no `cicd.yaml`/Trigger configuration could make this fire).
Publishing a GitHub Release also creates its underlying tag, which fires a real, working
`push` event - `event: tag` below is what actually catches that in practice, both for a
plain `git tag && git push --tags` and for clicking "Publish release" in GitHub's UI:

```yaml
apiVersion: platform/v1
kind: PipelineConfig
build:
  agent: nodejs-20
  script: ./build.sh

pipelines:
  manual-release:
    trigger:
      source: git
      event: tag
      tagPattern: "v[0-9]+\\.[0-9]+\\.[0-9]+"
    steps:
      - stage: release
        env: staging
        cluster: prod-cluster
```

`cluster` here is accepted (schema-validated, and `validateFlows` confirms it's only used
on a `release` step) but has **no effect yet** - `open-release-pr.yaml`'s target path is
currently the literal string `<app-name>/staging/deployment.yaml`, not derived from
`cluster` or `env` at all. It's a placeholder for the multi-cluster work described in
[architecture-plan.md](architecture-plan.md), kept in the schema now so today's
`cicd.yaml` files don't need a breaking change once that lands - don't rely on different
`cluster` values actually routing anywhere different today.

**Example 3: Build with file-path filtering**

Only trigger the pipeline when certain files change:

```yaml
apiVersion: platform/v1
kind: PipelineConfig
build:
  agent: nodejs-20
  script: ./build.sh

pipelines:
  api-pipeline:
    trigger:
      source: git
      event: push
      filePathPattern: ["api/**", "build.sh"]
    steps:
      - stage: build
      - stage: test
      - stage: deploy
        env: dev
```

**Example 4: Multiple environments in one flow**

Promote through dev → staging with automatic tests, then open a release PR for human review before prod:

```yaml
apiVersion: platform/v1
kind: PipelineConfig
build:
  agent: nodejs-20
  script: ./build.sh

pipelines:
  main-ci-cd:
    trigger:
      source: git
      event: push
      branch: main
    steps:
      - stage: build
      - stage: test
      - stage: deploy
        env: dev
      - stage: deploy
        env: staging
      - stage: release
        cluster: prod-cluster
```

**Example 5: Separate flows for release branches**

Distinct flow for release/* branches - these skip dev testing and go straight to staging + release:

```yaml
apiVersion: platform/v1
kind: PipelineConfig
build:
  agent: nodejs-20
  script: ./build.sh

pipelines:
  main-flow:
    trigger:
      source: git
      event: push
      branch: main
    steps:
      - stage: build
      - stage: test
      - stage: deploy
        env: dev

  release-flow:
    trigger:
      source: git
      event: branch.created
      branch: "release/*"
    steps:
      - stage: build
      - stage: deploy
        env: staging
      - stage: release
        cluster: prod-cluster
```

### Event-chained flows (downstream chaining)

Stages after the root are always event-chained - they're triggered by CDEvents emitted by the previous stage, not by new git events. This is automatic: when you declare a multi-stage `steps:` list, the platform wires up the event triggers for you.

The **only exception** is if you omit a stage from the flow - say, you configure `build` → `deploy` with no `test` stage. In that case, `deploy` still waits for `artifact.published` from `build`; the platform doesn't create a path for `build` to directly trigger `deploy`. If you need to skip stages conditionally, use the app's own cicd.yaml to enable/disable stages, not the pipelines flow structure.

### Migration from legacy list form

Earlier cicd.yaml files used a list form for the `pipelines:` field:

```yaml
# Legacy (still supported) list form
pipelines:
  - task: build
    trigger: push
    branch: main
  - task: test
  - task: deploy
    triggerEnv: dev
```

This is automatically normalized to the new object form internally. The new form is preferred for clarity, especially when naming flows or using event-based triggers.

### Local validation before pushing

Run `yajsv -s schemas/cicd.schema.json <(yq -o=json . cicd.yaml)` locally (same tool
`validate-cicd-config` uses) to catch schema errors before a push burns a pipeline run
finding them for you.
