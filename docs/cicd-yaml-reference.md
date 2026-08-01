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

## Staleness of the platform-generated boilerplate

`cicd.yaml` itself never goes stale (see above), but the two files onboarding generates
into `.tekton/` (`push.yaml`, `pull-request.yaml`) reference the shared catalog by
Pipeline name and param list - if the catalog adds a required param or a new trigger
type, those files need a re-sync. This isn't automated yet (Phase 1 hand-generates them
for pilot repos); a periodic diff-against-current-template check, surfaced as a "stale
integration" flag in the Grafana dashboard, is a named follow-up - see the plan's Q3
review notes. Don't assume `.tekton/*.yaml` silently stays current.

## Local validation before pushing

Run `yajsv -s schemas/cicd.schema.json <(yq -o=json . cicd.yaml)` locally (same tool
`validate-cicd-config` uses) to catch schema errors before a push burns a pipeline run
finding them for you.
