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

{% comment %} {{- define "babamba.vault.annotations" -}}
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: {{ .Values.vault.role | quote }}
{{- if .Values.vault.tlsSkipVerify }}
vault.hashicorp.com/tls-skip-verify: "true"
{{- end }} {% endcomment %}

{% comment %} # 최종 출력 파일 이름 (예: /vault/secrets/env)
vault.hashicorp.com/agent-inject-secret-{{ .Values.vault.outputFile }}: {{ (index .Values.vault.secrets 0).path | quote }} {% endcomment %}

{% comment %} # 여러 secret path를 하나 파일로 합쳐서 env 형태로 생성
vault.hashicorp.com/agent-inject-template-{{ .Values.vault.outputFile }}: |
  {{- range $s := .Values.vault.secrets }}
  {{- with secret $s.path }}
  {{- range $k := $s.keys }}
  {{ $k }}={{ index .Data.data $k }}
  {{- end }}
  {{- end }}
  {{- end }}
{{- end }} {% endcomment %}
