{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $service := mergeOverwrite (dict) $.Values.global.service (default dict $instance.service) -}}
{{- $acpService := mergeOverwrite (dict) $.Values.global.acpService (default dict $instance.acpService) -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "control-plane.serviceName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.webCommonLabels" $ctx | nindent 4 }}
{{- if $service.annotations }}
  annotations:
{{- range $key := keys $service.annotations | sortAlpha }}
    {{ $key }}: {{ index $service.annotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  type: {{ $service.type }}
  selector:{{ include "control-plane.webSelectorLabels" $ctx | nindent 4 }}
  ports:
    - name: http
      port: {{ $service.port }}
      targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "control-plane.acpServiceName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.acpCommonLabels" $ctx | nindent 4 }}
{{- if $acpService.annotations }}
  annotations:
{{- range $key := keys $acpService.annotations | sortAlpha }}
    {{ $key }}: {{ index $acpService.annotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  type: {{ $acpService.type }}
  selector:{{ include "control-plane.acpSelectorLabels" $ctx | nindent 4 }}
  ports:
    - name: acp
      port: {{ $acpService.port }}
      targetPort: acp
---
{{- end }}
