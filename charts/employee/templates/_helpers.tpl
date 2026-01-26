{{- define "employee-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "employee-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "employee-server.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "employee-server.labels" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}