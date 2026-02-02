{{- define "employee-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "employee-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "employee-server.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "employee-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "employee-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "employee-server.selectorLabels" . }}
{{- end -}}

{{/* GET 전용 selector */}}
{{- define "employee-server.selectorLabels.get" -}}
{{ include "employee-server.selectorLabels" . }}
traffic: get
{{- end -}}

{{/* WRITE 전용 selector */}}
{{- define "employee-server.selectorLabels.write" -}}
{{ include "employee-server.selectorLabels" . }}
traffic: write
{{- end -}}