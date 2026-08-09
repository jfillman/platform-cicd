{{/*
platform-cicd-app.hasStage - checks whether any flow in `.Values.pipelines` contains
an explicit stage entry for the requested stage name. This keeps the chart fully aligned
with the new flow-based model instead of relying on the old top-level `pipeline:` array.

Usage: {{ include "platform-cicd-app.hasStage" (dict "ctx" . "name" "test") }}
Returns the string "true" or "" (empty) - compare with `eq ... "true"`, matching Helm's
usual idiom for boolean-shaped named templates (a named template can only return a
string, not a real bool).
*/}}
{{- define "platform-cicd-app.hasStage" -}}
{{- $targetName := .name | default "" -}}
{{- $flows := dict -}}
{{- if hasKey . "ctx" -}}
  {{- $flows = .ctx.Values.pipelines | default (dict) -}}
{{- else -}}
  {{- $flows = .Values.pipelines | default (dict) -}}
{{- end -}}
{{- $found := "" -}}
{{- range $flowName, $flow := $flows -}}
  {{- $normalizedFlow := fromYaml (include "platform-cicd-app.normalizeFlow" (dict "flow" $flow)) -}}
  {{- $steps := $normalizedFlow.steps | default (list) -}}
  {{- range $step := $steps -}}
    {{- if eq ($step.stage | default "") $targetName -}}
      {{- $found = "true" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
platform-cicd-app.cacheSize - t-shirt size lookup for build.cache.size, replacing the
manual pre-substitution the pre-Helm onboarding process needed (there was no templating
engine in the app-resource path to do this lookup live - see
charts/platform-cicd-app/templates/env/build-cache-pvc.yaml). Same dictionary as the
user's own prior cd-pipelines-user Helm chart's buildSpec.cacheSize, reused as-is.
Defaults to "small" if unset, matching docs/cicd-yaml-reference.md.
*/}}
{{- define "platform-cicd-app.cacheSize" -}}
{{- $size := .size | default "small" -}}
{{- if eq $size "small" -}}1Gi
{{- else if eq $size "medium" -}}2.5Gi
{{- else if eq $size "large" -}}5Gi
{{- else if eq $size "xlarge" -}}8Gi
{{- else -}}1Gi
{{- end -}}
{{- end -}}

{{/*
platform-cicd-app.envNamespace - the one general namespace pattern this whole platform
uses: `<type>-<app-name>-<env>`, where every namespace an Application ever gets (its own
CI/CD execution namespace, a deploy target, release staging, a PR ephemeral env) is a
PEER under this same flat pattern, not a hierarchy - a deploy namespace is never
`<type>-<app-name>-cicd-<env>`, since it has nothing to do with "cicd" conceptually (it's
where the Application *runs*, not where its pipeline runs). See docs/concepts.md and
docs/naming-conventions.md for the full rationale.

Takes a two-element list, [<root context>, <env value>], since Helm named templates only
accept one positional argument - `list` is the idiom for passing more than one.

Usage: {{ include "platform-cicd-app.envNamespace" (list $ "staging") }}
*/}}
{{- define "platform-cicd-app.envNamespace" -}}
{{- $ctx := index . 0 -}}
{{- $env := index . 1 -}}
{{- $ctx.Values.platformIdentity.type }}-{{ $ctx.Values.platformIdentity.appName }}-{{ $env }}
{{- end -}}

{{/*
platform-cicd-app.namespace - the Application's own CI/CD execution namespace, i.e.
platform-cicd-app.envNamespace with env="cicd" - just the specific env value this
Application's pipelines themselves run under, a sibling of "dev"/"staging"/"pr-42", not a
special base other namespaces are built on top of. This is the by-far most common case
(every resource that isn't itself env-scoped lives here), so it gets its own shorthand
taking the context directly rather than needing `(list $ "cicd")` at every call site.

Usage: {{ include "platform-cicd-app.namespace" . }} (or `$` from inside a range/with block)
*/}}
{{- define "platform-cicd-app.namespace" -}}
{{- include "platform-cicd-app.envNamespace" (list . "cicd") -}}
{{- end -}}

{{/*
platform-cicd-app.normalizeFlow - accepts either the newer object form
  pipelines:
    ci:
      trigger: { type: branch.created }
      steps: [ ... ]

or the legacy list form that the old config used:
  pipelines:
    ci:
      - task: build
        trigger: branch.created

The normalized result is a dict with a `trigger` object and a `steps` list so the
renderer can treat both forms uniformly.
*/}}
{{- define "platform-cicd-app.normalizeFlow" -}}
{{- $flow := .flow -}}
{{- $rootTrigger := dict -}}
{{- $steps := list -}}
{{- if kindIs "slice" $flow -}}
  {{- range $idx, $entry := $flow -}}
    {{- $step := dict -}}
    {{- if hasKey $entry "task" -}}
      {{- $_ := set $step "stage" $entry.task -}}
    {{- else if hasKey $entry "stage" -}}
      {{- $_ := set $step "stage" $entry.stage -}}
    {{- end -}}
    {{- if hasKey $entry "env" -}}
      {{- $_ := set $step "env" $entry.env -}}
    {{- end -}}
    {{- if hasKey $entry "cluster" -}}
      {{- $_ := set $step "cluster" $entry.cluster -}}
    {{- end -}}
    {{- if hasKey $entry "name" -}}
      {{- $_ := set $step "name" $entry.name -}}
    {{- end -}}
    {{- if hasKey $entry "approvalRequired" -}}
      {{- $_ := set $step "approvalRequired" $entry.approvalRequired -}}
    {{- end -}}
    {{- if eq $idx 0 -}}
      {{- if hasKey $entry "trigger" -}}
        {{- $entryTrigger := $entry.trigger -}}
        {{- if kindIs "map" $entryTrigger -}}
          {{- if hasKey $entryTrigger "source" -}}
            {{- $_ := set $rootTrigger "source" (get $entryTrigger "source") -}}
          {{- end -}}
          {{- if hasKey $entryTrigger "event" -}}
            {{- $_ := set $rootTrigger "event" (get $entryTrigger "event") -}}
          {{- end -}}
          {{- if hasKey $entryTrigger "type" -}}
            {{- $_ := set $rootTrigger "type" (get $entryTrigger "type") -}}
            {{- if not (hasKey $entryTrigger "event") -}}
              {{- $_ := set $rootTrigger "event" (get $entryTrigger "type") -}}
            {{- end -}}
          {{- end -}}
        {{- else if kindIs "string" $entryTrigger -}}
          {{- $_ := set $rootTrigger "source" "git" -}}
          {{- $_ := set $rootTrigger "event" $entryTrigger -}}
          {{- $_ := set $rootTrigger "type" $entryTrigger -}}
        {{- end -}}
      {{- end -}}
      {{- if hasKey $entry "branch" -}}
        {{- $_ := set $rootTrigger "branch" $entry.branch -}}
      {{- end -}}
      {{- if hasKey $entry "branchPattern" -}}
        {{- $_ := set $rootTrigger "branchPattern" $entry.branchPattern -}}
      {{- end -}}
      {{- if hasKey $entry "tagPattern" -}}
        {{- $_ := set $rootTrigger "tagPattern" $entry.tagPattern -}}
      {{- end -}}
      {{- if hasKey $entry "filePathPattern" -}}
        {{- $_ := set $rootTrigger "filePathPattern" $entry.filePathPattern -}}
      {{- end -}}
    {{- end -}}
    {{- $steps = append $steps $step -}}
  {{- end -}}
{{- else if kindIs "map" $flow -}}
  {{- if hasKey $flow "trigger" -}}
    {{- $flowTrigger := get $flow "trigger" -}}
    {{- if kindIs "map" $flowTrigger -}}
      {{- if hasKey $flowTrigger "source" -}}
        {{- $_ := set $rootTrigger "source" (get $flowTrigger "source") -}}
      {{- end -}}
      {{- if hasKey $flowTrigger "event" -}}
        {{- $_ := set $rootTrigger "event" (get $flowTrigger "event") -}}
      {{- end -}}
      {{- if hasKey $flowTrigger "type" -}}
        {{- $_ := set $rootTrigger "type" (get $flowTrigger "type") -}}
        {{- if not (hasKey $flowTrigger "event") -}}
          {{- $_ := set $rootTrigger "event" (get $flowTrigger "type") -}}
        {{- end -}}
      {{- end -}}
    {{- else if kindIs "string" $flowTrigger -}}
      {{- $_ := set $rootTrigger "source" "git" -}}
      {{- $_ := set $rootTrigger "event" $flowTrigger -}}
      {{- $_ := set $rootTrigger "type" $flowTrigger -}}
    {{- end -}}
    {{- if hasKey $flow.trigger "branch" -}}
      {{- $_ := set $rootTrigger "branch" (get $flow.trigger "branch") -}}
    {{- end -}}
    {{- if hasKey $flow.trigger "branchPattern" -}}
      {{- $_ := set $rootTrigger "branchPattern" (get $flow.trigger "branchPattern") -}}
    {{- end -}}
    {{- if hasKey $flow.trigger "tagPattern" -}}
      {{- $_ := set $rootTrigger "tagPattern" (get $flow.trigger "tagPattern") -}}
    {{- end -}}
    {{- if hasKey $flow.trigger "filePathPattern" -}}
      {{- $_ := set $rootTrigger "filePathPattern" (get $flow.trigger "filePathPattern") -}}
    {{- end -}}
  {{- end -}}
  {{- if hasKey $flow "steps" -}}
    {{- range $entry := $flow.steps -}}
      {{- $step := dict -}}
      {{- if hasKey $entry "stage" -}}
        {{- $_ := set $step "stage" $entry.stage -}}
      {{- end -}}
      {{- if hasKey $entry "env" -}}
        {{- $_ := set $step "env" $entry.env -}}
      {{- end -}}
      {{- if hasKey $entry "cluster" -}}
        {{- $_ := set $step "cluster" $entry.cluster -}}
      {{- end -}}
      {{- if hasKey $entry "name" -}}
        {{- $_ := set $step "name" $entry.name -}}
      {{- end -}}
      {{- if hasKey $entry "approvalRequired" -}}
        {{- $_ := set $step "approvalRequired" $entry.approvalRequired -}}
      {{- end -}}
      {{- $steps = append $steps $step -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if eq ($rootTrigger.source | default "") "" -}}
  {{- $defaultEvent := $rootTrigger.event | default ($rootTrigger.type | default "") -}}
  {{- /* No release.created - see flow-triggers.yaml's own header for why it was removed
  entirely (PaC has no support for GitHub "release" webhooks at all). Includes
  pull_request/tag, unlike an earlier version of this check - validateFlows below has its
  own, separate re-derivation of the same "is this git-rooted" inference that already had
  both, so a flow using the legacy `type: tag`/`type: pull_request` shorthand without an
  explicit `source: git` was inferred as event-chained HERE but git-rooted THERE,
  depending on which of the two independent checks happened to run. */ -}}
  {{- if or (eq $defaultEvent "push") (eq $defaultEvent "pull_request") (eq $defaultEvent "branch.created") (eq $defaultEvent "tag") (eq $defaultEvent "deploy") -}}
    {{- $_ := set $rootTrigger "source" "git" -}}
  {{- else if ne $defaultEvent "" -}}
    {{- $_ := set $rootTrigger "source" "event" -}}
  {{- end -}}
{{- end -}}
{{- dict "trigger" $rootTrigger "steps" $steps | toYaml -}}
{{- end -}}

{{/*
platform-cicd-app.labels - see charts/platform-cicd-catalog/templates/_helpers.tpl's
identical-in-spirit helper for the full rationale. Includes platform.io/app
unconditionally (not just on the argocd-namespace resources that strictly need it for
selection) - most valuable there, where many Applications' Applications/AppProjects/Roles
coexist in one shared namespace, but applied everywhere for consistency per
docs/naming-conventions.md.
*/}}
{{/*
platform-cicd-app.validateFlows - validates pipeline flow definitions against
architectural constraints. Rules:
- Any stage (build/test/deploy/release) may be git-rooted (source: git) - all four
  Pipelines' start-flow task is idempotent (generates a new trace root when fired
  directly, passes through when event-chained), so none of them are special-cased here
  anymore. See start-flow-root-span.yaml.
- build, if present in a flow at all, must be its first step - nothing else emits an
  event build could sensibly be chained from, and nothing chains FROM build via this
  rule either (build must be root when present).
- Release as git-root must still be first (only) step in flow - it's architecturally
  terminal for the GIT-ROOTED case specifically (a git-rooted release creates a new
  trace root with nothing before it to chain from); this does NOT restrict where an
  EVENT-CHAINED release can appear - test/deploy/release/repeats of any of them may
  precede or follow each other in any combination once past a required leading build.
  Deliberately no "release must follow deploy" or "release must be last" rule -
  flow-triggers.yaml's event-type lookup is keyed by whatever the PREVIOUS step's
  stage actually is, not a fixed position, so any ordering already works structurally.
- Cluster param only valid for release stage
- Env param required for deploy and release stages

Fails fast with descriptive message if violated, preventing broken renders.
*/}}
{{- define "platform-cicd-app.validateFlows" -}}
{{- $flows := .Values.pipelines | default (dict) -}}
{{- range $flowName, $flow := $flows -}}
  {{- $normalized := fromYaml (include "platform-cicd-app.normalizeFlow" (dict "flow" $flow)) -}}
  {{- $trigger := $normalized.trigger | default (dict) -}}
  {{- $steps := $normalized.steps | default (list) -}}
  {{- $stepCount := len $steps -}}

  {{- if gt $stepCount 0 -}}
    {{- /* Determine trigger source */ -}}
    {{- $triggerSource := $trigger.source | default "" -}}
    {{- if eq $triggerSource "" -}}
      {{- $triggerEvent := $trigger.event | default ($trigger.type | default "") -}}
      {{- if or (eq $triggerEvent "push") (eq $triggerEvent "pull_request") (eq $triggerEvent "branch.created") (eq $triggerEvent "tag") -}}
        {{- $triggerSource = "git" -}}
      {{- else if ne $triggerEvent "" -}}
        {{- $triggerSource = "event" -}}
      {{- end -}}
    {{- end -}}

    {{- $firstStage := (index $steps 0).stage | default "build" -}}

    {{- /* Validate git-rooted stages */ -}}
    {{- if eq $triggerSource "git" -}}
      {{- if eq $firstStage "release" -}}
        {{- if gt $stepCount 1 -}}
          {{- fail (printf "Flow '%s': git-rooted release must be first (and only) step in flow to create a new trace root. For release that continues existing trace, make it event-chained (final step after deploy)." $flowName) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}

    {{- /* Validate each step */ -}}
    {{- range $index, $step := $steps -}}
      {{- $stageName := $step.stage | default "" -}}

      {{- /* Validate env requirement */ -}}
      {{- if or (eq $stageName "deploy") (eq $stageName "release") -}}
        {{- if not $step.env -}}
          {{- fail (printf "Flow '%s' step %d (%s): env is required for %s stage" $flowName (add $index 1) $stageName $stageName) -}}
        {{- end -}}
      {{- end -}}

      {{- /* Validate cluster only for release */ -}}
      {{- if and $step.cluster (ne $stageName "release") -}}
        {{- fail (printf "Flow '%s' step %d: cluster is only valid for release stage, not %s" $flowName (add $index 1) $stageName) -}}
      {{- end -}}

      {{- /* Validate trigger only on first step */ -}}
      {{- if and (gt $index 0) $step.trigger -}}
        {{- fail (printf "Flow '%s' step %d: trigger can only be defined on first step, not step %d (%s)" $flowName 1 (add $index 1) $stageName) -}}
      {{- end -}}

      {{- /* Validate build can only ever be the first step */ -}}
      {{- if and (eq $stageName "build") (gt $index 0) -}}
        {{- fail (printf "Flow '%s' step %d: build can only be the first step of a flow, not step %d - nothing chains into build. Give it its own flow, or move it to step 1." $flowName (add $index 1) (add $index 1)) -}}
      {{- end -}}
    {{- end -}}

    {{- /* Validate tag patterns for tag-triggered flows */ -}}
    {{- $triggerEvent := $trigger.event | default ($trigger.type | default "") -}}
    {{- if eq $triggerEvent "tag" -}}
      {{- $tagPattern := $trigger.tagPattern | default "" -}}
      {{- if not $tagPattern -}}
        {{- fail (printf "Flow '%s': trigger.tagPattern is required when event is 'tag' (e.g., 'v[0-9]+.[0-9]+.[0-9]+')" $flowName) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "platform-cicd-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-cicd
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
platform.io/component: app
platform.io/app: {{ .Values.platformIdentity.appName }}
{{- end -}}
