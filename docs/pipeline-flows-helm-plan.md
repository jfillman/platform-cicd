# Pipeline flow Helm schema and rendering plan

## Goal

Support app-defined sequential CI/CD flows in the platform chart without hand-writing Tekton YAML. The chart should accept a list of pipeline steps per flow, convert them into a normalized internal model, and render the right Tekton Trigger resources for each step.

This proposal fits the existing app chart structure in [charts/platform-cicd-app](../charts/platform-cicd-app) and keeps the current stage-based platform model (`build`, `test`, `deploy`, `release`) intact.

## Proposed values contract

Add an optional values block under the app chart values, using the same top-level shape the current legacy config already uses:

```yaml
pipelines:
  ci:
    trigger:
      type: branch.created
      branch: "release/.*"
    steps:
      - stage: build
      - stage: deploy
        env: test
      - stage: test
        env: test
        name: e2e
      - stage: deploy
        env: rel
      - stage: test
        env: rel
        name: e2e
      - stage: release
        env: prod
        cluster: aropod

  cd:
    trigger:
      type: release.created
    steps:
      - stage: release
        env: prod
        cluster: aropod
```

### Explicit trigger shape

The preferred form for a flow trigger is now explicit and schema-driven:

```yaml
pipelines:
  ci:
    trigger:
      source: git
      event: push
      branch: main
      filePathPattern:
        - "src/**"
    steps:
      - stage: build
      - stage: deploy
        env: dev
```

This makes the intended behavior visible to both humans and tooling: `source: git` means the flow starts from a git-originated event, while `event` names the concrete trigger kind and the optional branch/path filters refine it.

### Compatibility with the existing list style

The repo already has a legacy shape similar to this:

```yaml
pipelines:
  ci:
    - task: build
      trigger: branch.created
      branch: "release/.*"
    - task: deploy
      env: test
```

For compatibility, the chart can accept either:

- the normalized `steps:` form above, or
- the legacy list form, which is normalized by a small pre-render transform before Helm template rendering.

The normalized form is the internal contract; the legacy list is a compatibility input.

## Normalized model

Each flow is normalized into:

```yaml
flowName: ci
rootTrigger:
  type: branch.created
  branch: "release/.*"
steps:
  - id: build-1
    stage: build
  - id: deploy-1
    stage: deploy
    env: test
    after: build-1
  - id: test-1
    stage: test
    env: test
    name: e2e
    after: deploy-1
```

### Validation rules

The renderer should enforce:

- `stage` is one of `build`, `test`, `deploy`, `release`
- `after` references an earlier step in the same flow
- `env` is required for `deploy` and `release`
- `cluster` is only valid for `release`
- `name` is optional and used for test-suite naming
- the first step may define a root trigger; later steps inherit the previous stage completion as the trigger source

## Rendering plan

### 1. Extend the chart values

Update [charts/platform-cicd-app/values.yaml](../charts/platform-cicd-app/values.yaml) with a new optional block such as:

```yaml
pipelines: {}
```

This keeps the current chart defaults backward-compatible while allowing app-specific flows to be supplied via values.

### 2. Add helper functions

Extend [charts/platform-cicd-app/templates/_helpers.tpl](../charts/platform-cicd-app/templates/_helpers.tpl) with helpers to:

- list flow names
- determine whether a flow has a root trigger
- build a stable trigger/template name for each step
- build a stable label/annotation key for the flow and step

### 3. Render one Trigger set per flow step

The current chart already renders stage-specific triggers in [charts/platform-cicd-app/templates/triggers](../charts/platform-cicd-app/templates/triggers):

- [charts/platform-cicd-app/templates/triggers/fire-test.yaml](../charts/platform-cicd-app/templates/triggers/fire-test.yaml)
- [charts/platform-cicd-app/templates/triggers/fire-deploy.yaml](../charts/platform-cicd-app/templates/triggers/fire-deploy.yaml)
- [charts/platform-cicd-app/templates/triggers/fire-release.yaml](../charts/platform-cicd-app/templates/triggers/fire-release.yaml)

The new flow renderer should generate the equivalent of these resources for each flow step, but dynamically:

- the first step gets a root trigger based on the flow’s root trigger
- each later step gets a trigger bound to the previous step’s completion event
- the `PipelineRun` created by the trigger references the right catalog pipeline (`build`, `test`, `deploy`, or `release`) and passes the right params (`env`, `cluster`, `name`, etc.)

### 4. Reuse the existing catalog pipelines

Do not create a bespoke Tekton Pipeline for every flow. Reuse the existing shared catalog pipelines and inject parameters per step.

That means the flow renderer only needs to decide:

- which pipeline name to call
- which params to pass
- whether the trigger is root-based or event-based

### 5. Keep the current single-stage model intact

The current `.Values.pipeline` array remains useful for the simple fixed DAG model. The new flow renderer should be additive:

- if `pipelines` is present, render multi-flow triggers from it
- otherwise, continue using the existing stage-based trigger templates

This avoids breaking current onboarding behavior.

## Suggested file changes

- [charts/platform-cicd-app/values.yaml](../charts/platform-cicd-app/values.yaml): add the new `pipelines` values block
- [charts/platform-cicd-app/templates/_helpers.tpl](../charts/platform-cicd-app/templates/_helpers.tpl): add helpers for flow normalization and naming
- [charts/platform-cicd-app/templates/triggers](../charts/platform-cicd-app/templates/triggers): add flow-specific trigger templates or a shared template that loops over each flow
- [schemas/cicd.schema.json](../schemas/cicd.schema.json): add validation for `pipelines` and the normalized step shape
- [docs/cicd-yaml-reference.md](./cicd-yaml-reference.md): document the new flow schema and the compatibility rule

## Rendering example

For a flow like this:

```yaml
pipelines:
  ci:
    trigger:
      type: branch.created
      branch: "release/.*"
    steps:
      - stage: build
      - stage: deploy
        env: test
      - stage: test
        env: test
        name: e2e
```

The chart would render:

1. one root trigger for `ci` step 1 (`build`)
2. one event-driven trigger for `ci` step 2 (`deploy`), fired when the build stage succeeds
3. one event-driven trigger for `ci` step 3 (`test`), fired when the deploy stage succeeds

That keeps the model fully declarative while still honoring the repo’s existing event-driven chaining approach.

## Recommendation

Implement this as a thin normalization layer plus a generic renderer over the existing stage-specific pipelines. That is the smallest change that gives you a real multi-step flow model without introducing a second custom pipeline engine.
