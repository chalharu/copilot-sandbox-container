{{- $seenMainNamespaces := dict -}}
{{- $seenJobNamespaces := dict -}}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
{{- if not (hasKey $seenMainNamespaces $mainNamespace) }}
{{- $_ := set $seenMainNamespaces $mainNamespace true -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.execServiceAccountName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
---
{{- end }}
{{- if not (hasKey $seenJobNamespaces $jobNamespace) }}
{{- $_ := set $seenJobNamespaces $jobNamespace true -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "control-plane.jobServiceAccountName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
---
{{- end }}
{{- end }}
