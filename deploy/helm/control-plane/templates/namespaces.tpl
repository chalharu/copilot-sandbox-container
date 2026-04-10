{{- if .Values.global.createNamespaces }}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
{{- end }}
{{- end }}
