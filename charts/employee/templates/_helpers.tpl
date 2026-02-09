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

{{/*
KEDA enabled switch per traffic role (get/write).
- If keda.<role>.enabled exists, it overrides global keda.enabled
- Else fall back to global keda.enabled (default: false)
*/}}
{{- define "employee-server.kedaEnabled.get" -}}
{{- if and (hasKey .Values "keda") (hasKey .Values.keda "get") (hasKey .Values.keda.get "enabled") -}}
{{- ternary "true" "false" .Values.keda.get.enabled -}}
{{- else -}}
{{- ternary "true" "false" (.Values.keda.enabled | default false) -}}
{{- end -}}
{{- end -}}

{{- define "employee-server.kedaEnabled.write" -}}
{{- if and (hasKey .Values "keda") (hasKey .Values.keda "write") (hasKey .Values.keda.write "enabled") -}}
{{- ternary "true" "false" .Values.keda.write.enabled -}}
{{- else -}}
{{- ternary "true" "false" (.Values.keda.enabled | default false) -}}
{{- end -}}
{{- end -}}