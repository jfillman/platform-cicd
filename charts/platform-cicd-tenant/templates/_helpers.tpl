{{/*
platform-cicd-tenant.hasStage - the direct fix for the enforcement gap this whole chart
exists to close: cicd.yaml's `pipeline:` field was schema-validated but never actually
read by anything (confirmed live: a `release` PipelineRun fired for a tenant whose
cicd.yaml only declared build/test/deploy). Every conditional resource in this chart
keys off this helper instead of assuming a stage is present.

Deliberately a simple membership check, not real DAG evaluation: this platform's own
schema docs describe pipeline as a "fixed superset DAG, not arbitrary graphs" - the
`after` field on each stage entry is validated by the schema but the broker's trigger
wiring (see templates/triggers/*.yaml) is hardcoded to the specific build->test->deploy->
release sequence regardless of what `after` says. This helper faithfully replicates that
existing, real behavior (present/absent toggle) rather than building DAG flexibility
nothing in this platform actually uses yet.

Usage: {{ include "platform-cicd-tenant.hasStage" (dict "stages" .Values.pipeline "name" "test") }}
Returns the string "true" or "" (empty) - compare with `eq ... "true"`, matching Helm's
usual idiom for boolean-shaped named templates (a named template can only return a
string, not a real bool).
*/}}
{{- define "platform-cicd-tenant.hasStage" -}}
{{- $found := "" -}}
{{- range .stages -}}
{{- if eq .stage $.name -}}
{{- $found = "true" -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
platform-cicd-tenant.cacheSize - t-shirt size lookup for build.cache.size, replacing the
manual pre-substitution the pre-Helm onboarding process needed (there was no templating
engine in the tenant-resource path to do this lookup live - see
charts/platform-cicd-tenant/templates/env/build-cache-pvc.yaml). Same dictionary as the
user's own prior cd-pipelines-user Helm chart's buildSpec.cacheSize, reused as-is.
Defaults to "small" if unset, matching docs/cicd-yaml-reference.md.
*/}}
{{- define "platform-cicd-tenant.cacheSize" -}}
{{- $size := .size | default "small" -}}
{{- if eq $size "small" -}}1Gi
{{- else if eq $size "medium" -}}2.5Gi
{{- else if eq $size "large" -}}5Gi
{{- else if eq $size "xlarge" -}}8Gi
{{- else -}}1Gi
{{- end -}}
{{- end -}}
