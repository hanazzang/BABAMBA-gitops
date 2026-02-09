{{- define "photo-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "photo-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "photo-server.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "photo-server.labels" -}}
app.kubernetes.io/name: {{ include "photo-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}