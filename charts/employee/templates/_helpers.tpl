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

{{- define "employee-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
# ArgoCD 앱 이름(Release.Name) 대신 fullname으로 고정하여 접두사 차단
app.kubernetes.io/instance: {{ include "employee-server.name" . }} 
{{- end -}}

{{- define "employee-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "employee-server.selectorLabels" . }}
{{- end -}}