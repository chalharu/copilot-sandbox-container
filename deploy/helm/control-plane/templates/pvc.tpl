{{- $seenSessionClaims := dict -}}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $workspace := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.workspace)) (deepCopy (default dict $instance.workspace)) -}}
{{- $session := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.session)) (deepCopy (default dict $instance.session)) -}}
{{- if not $workspace.existingClaim }}
{{- $workspaceAnnotations := mergeOverwrite (dict) (deepCopy (default dict $workspace.annotations)) -}}
{{- if $workspace.retainOnDelete }}
{{- $_ := set $workspaceAnnotations "helm.sh/resource-policy" "keep" -}}
{{- end }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "control-plane.workspaceClaimName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
{{- if $workspaceAnnotations }}
  annotations:
{{- range $key := keys $workspaceAnnotations | sortAlpha }}
    {{ $key }}: {{ index $workspaceAnnotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  accessModes:
{{ toYaml $workspace.accessModes | nindent 4 }}
  resources:
    requests:
      storage: {{ $workspace.size }}
  storageClassName: {{ $workspace.storageClassName | quote }}
---
{{- end }}
{{- $sessionClaimName := include "control-plane.sessionClaimName" $ctx -}}
{{- $sessionKey := printf "%s/%s" (include "control-plane.instanceMainNamespace" $ctx) $sessionClaimName -}}
{{- if and (not $session.existingClaim) (not (hasKey $seenSessionClaims $sessionKey)) }}
{{- $_ := set $seenSessionClaims $sessionKey true -}}
{{- $sessionAnnotations := mergeOverwrite (dict) (deepCopy (default dict $session.annotations)) -}}
{{- if $session.retainOnDelete }}
{{- $_ := set $sessionAnnotations "helm.sh/resource-policy" "keep" -}}
{{- end }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $sessionClaimName }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.releaseLabels" $ctx | nindent 4 }}
{{- if $sessionAnnotations }}
  annotations:
{{- range $key := keys $sessionAnnotations | sortAlpha }}
    {{ $key }}: {{ index $sessionAnnotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  accessModes:
{{ toYaml $session.accessModes | nindent 4 }}
  resources:
    requests:
      storage: {{ $session.size }}
  storageClassName: {{ $session.storageClassName | quote }}
---
{{- end }}
{{- end }}
