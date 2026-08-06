{{/*
platform-cicd-control-plane.labels - see charts/platform-cicd-catalog/templates/
_helpers.tpl's identical-in-spirit helper for the full rationale. Every resource in this
chart includes this via `{{- include "platform-cicd-control-plane.labels" . | nindent 4 }}`
under its own metadata.labels, then adds `platform.io/subcomponent: <broker|dora-exporter|
sigstore|secretstore|hooks>` alongside it - see docs/naming-conventions.md.
*/}}
{{- define "platform-cicd-control-plane.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-cicd
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
platform.io/component: control-plane
{{- end -}}
