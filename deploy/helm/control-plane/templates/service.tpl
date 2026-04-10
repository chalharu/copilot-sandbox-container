{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $service := mergeOverwrite (dict) $.Values.global.service (default dict $instance.service) -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "control-plane.serviceName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
{{- if $service.annotations }}
  annotations:
{{- range $key := keys $service.annotations | sortAlpha }}
    {{ $key }}: {{ index $service.annotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  type: {{ $service.type }}
  selector:{{ include "control-plane.selectorLabels" $ctx | nindent 4 }}
  ports:
    - name: ssh
      port: {{ $service.port }}
      targetPort: ssh
---
{{- end }}
