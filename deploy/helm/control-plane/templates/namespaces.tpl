{{- if .Values.global.createNamespaces }}
{{- $seenNamespaces := dict -}}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- if not (hasKey $seenNamespaces $mainNamespace) }}
{{- $_ := set $seenNamespaces $mainNamespace true -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ $mainNamespace }}
  labels:{{ include "control-plane.releaseLabels" $ctx | nindent 4 }}
---
{{- end }}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
{{- if not (hasKey $seenNamespaces $jobNamespace) }}
{{- $_ := set $seenNamespaces $jobNamespace true -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ $jobNamespace }}
  labels:{{ include "control-plane.releaseLabels" $ctx | nindent 4 }}
---
{{- end }}
{{- end }}
{{- end }}
