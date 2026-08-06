{{/*
platform-cicd-app.hasStage - the direct fix for the enforcement gap this whole chart
exists to close: cicd.yaml's `pipeline:` field was schema-validated but never actually
read by anything (confirmed live: a `release` PipelineRun fired for an Application whose
cicd.yaml only declared build/test/deploy). Every conditional resource in this chart
keys off this helper instead of assuming a stage is present.

Deliberately a simple membership check, not real DAG evaluation: this platform's own
schema docs describe pipeline as a "fixed superset DAG, not arbitrary graphs" - the
`after` field on each stage entry is validated by the schema but the broker's trigger
wiring (see templates/triggers/*.yaml) is hardcoded to the specific build->test->deploy->
release sequence regardless of what `after` says. This helper faithfully replicates that
existing, real behavior (present/absent toggle) rather than building DAG flexibility
nothing in this platform actually uses yet.

Usage: {{ include "platform-cicd-app.hasStage" (dict "stages" .Values.pipeline "name" "test") }}
Returns the string "true" or "" (empty) - compare with `eq ... "true"`, matching Helm's
usual idiom for boolean-shaped named templates (a named template can only return a
string, not a real bool).
*/}}
{{- define "platform-cicd-app.hasStage" -}}
{{- $found := "" -}}
{{- range .stages -}}
{{- if eq .stage $.name -}}
{{- $found = "true" -}}
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
platform-cicd-app.labels - see charts/platform-cicd-catalog/templates/_helpers.tpl's
identical-in-spirit helper for the full rationale. Includes platform.io/app
unconditionally (not just on the argocd-namespace resources that strictly need it for
selection) - most valuable there, where many Applications' Applications/AppProjects/Roles
coexist in one shared namespace, but applied everywhere for consistency per
docs/naming-conventions.md.
*/}}
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
