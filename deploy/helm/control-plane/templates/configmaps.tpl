{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
{{- $image := mergeOverwrite (dict) $.Values.global.image (default dict $instance.image) -}}
{{- $service := mergeOverwrite (dict) $.Values.global.service (default dict $instance.service) -}}
{{- $workspace := mergeOverwrite (dict) $.Values.global.workspace (default dict $instance.workspace) -}}
{{- $session := mergeOverwrite (dict) $.Values.global.session (default dict $instance.session) -}}
{{- $controlPlaneEnv := mergeOverwrite (dict) $.Values.global.controlPlaneEnv (default dict $instance.controlPlaneEnv) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_K8S_NAMESPACE" $mainNamespace -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_JOB_NAMESPACE" $jobNamespace -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_COPILOT_SESSION_PVC" (include "control-plane.sessionClaimName" $ctx) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH" ($session.ghSubPath | toString) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH" ($session.sshSubPath | toString) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_WORKSPACE_SUBPATH" ($workspace.subPath | toString) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT" (include "control-plane.execServiceAccountName" $ctx) -}}
{{- $_ := set $controlPlaneEnv "CONTROL_PLANE_JOB_SERVICE_ACCOUNT" (include "control-plane.jobServiceAccountName" $ctx) -}}
{{- $instanceEnv := mergeOverwrite (dict) $.Values.global.instanceEnv (default dict $instance.instanceEnv) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_WORKSPACE_PVC" (include "control-plane.workspaceClaimName" $ctx) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE" (include "control-plane.imageRef" (dict "image" $image)) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE_PULL_POLICY" ($image.pullPolicy | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_IMAGE" (include "control-plane.imageRef" (dict "image" $image)) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_HOST" (printf "%s.%s.svc.%s" (include "control-plane.serviceName" $ctx) $mainNamespace $.Values.global.clusterDomain) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_PORT" ($service.port | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_IMAGE_PULL_POLICY" ($image.pullPolicy | toString) -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.controlPlaneEnvConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
data:
{{- range $key := keys $controlPlaneEnv | sortAlpha }}
  {{ $key }}: {{ index $controlPlaneEnv $key | toString | quote }}
{{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.instanceEnvConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
data:
{{- range $key := keys $instanceEnv | sortAlpha }}
  {{ $key }}: {{ index $instanceEnv $key | toString | quote }}
{{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.controlPlaneConfigConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
data:
  copilot-config.json: |{{ default $.Values.global.controlPlaneConfigJson $instance.controlPlaneConfigJson | nindent 4 }}
---
{{- end }}
