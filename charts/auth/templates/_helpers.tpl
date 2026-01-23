{{- define "auth-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "auth-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "auth-server.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "auth-server.labels" -}}
app.kubernetes.io/name: {{ include "auth-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
