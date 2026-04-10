{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.execServiceAccountName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.jobServiceAccountName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
---
{{- end }}
