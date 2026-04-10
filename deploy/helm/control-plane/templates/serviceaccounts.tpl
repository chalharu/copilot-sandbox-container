{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.execServiceAccountName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.jobServiceAccountName" $ctx }}
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
{{- end }}
