{{/*
platform-cicd-catalog.labels - the standard Kubernetes-recommended label set
(app.kubernetes.io/*, for generic tooling interop: kubectl, Lens, ArgoCD's own resource
tree, etc.) plus this platform's own platform.io/component marker. Every resource in
this chart includes this via `{{- include "platform-cicd-catalog.labels" . | nindent 4 }}`
under its own metadata.labels, then adds any resource-specific labels
(platform.io/catalog, platform.io/stub) alongside it - see docs/naming-conventions.md.
*/}}
{{- define "platform-cicd-catalog.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-cicd
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
platform.io/component: catalog
{{- end -}}
