{{- define "photo-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "photo-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "photo-service.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "photo-service.labels" -}}
app.kubernetes.io/name: {{ include "photo-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}