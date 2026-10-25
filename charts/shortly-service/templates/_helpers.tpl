{{/* The app label and Datadog's unified service tagging labels. */}}
{{- define "shortly.labels" -}}
app: {{ .Release.Name }}
tags.datadoghq.com/env: {{ .Values.datadog.env | quote }}
tags.datadoghq.com/service: {{ .Release.Name | quote }}
tags.datadoghq.com/version: {{ .Values.datadog.version | quote }}
{{- end -}}

{{/* DD_* variables read back from those labels, plus the node-local agent address. */}}
{{- define "shortly.ddEnv" -}}
- name: DD_ENV
  valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/env']" } }
- name: DD_SERVICE
  valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/service']" } }
- name: DD_VERSION
  valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/version']" } }
- name: DD_AGENT_HOST
  valueFrom: { fieldRef: { fieldPath: "status.hostIP" } }
{{- end -}}
