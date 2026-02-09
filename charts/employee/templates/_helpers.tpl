{{/* 서비스 이름 정의 */}}
{{- define "employee-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 전체 이름(Fullname) 정의 - 접두사 제거를 위해 nameOverride나 Chart.Name 기반 */}}
{{- define "employee-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "employee-server.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* 공통 라벨 */}}
{{- define "employee-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_") }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "employee-server.selectorLabels" . }}
{{- end -}}

{{/* 기본 셀렉터 라벨 (instance를 name으로 고정하여 접두사 차단) */}}
{{- define "employee-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
app.kubernetes.io/instance: {{ include "employee-server.name" . }}
{{- end -}}

{{/* 🔍 Get 서비스 전용 셀렉터 라벨 (에러 해결 핵심) */}}
{{- define "employee-server.selectorLabels.get" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
app.kubernetes.io/instance: {{ include "employee-server.name" . }}
traffic: get
{{- end -}}

{{/* 🔍 Write 서비스 전용 셀렉터 라벨 (에러 해결 핵심) */}}
{{- define "employee-server.selectorLabels.write" -}}
app.kubernetes.io/name: {{ include "employee-server.name" . }}
app.kubernetes.io/instance: {{ include "employee-server.name" . }}
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