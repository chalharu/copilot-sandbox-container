{{- $seenGlobalEnvNamespaces := dict -}}
{{- $seenGlobalConfigNamespaces := dict -}}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
{{- $image := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.image)) (deepCopy (default dict $instance.image)) -}}
{{- $service := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.service)) (deepCopy (default dict $instance.service)) -}}
{{- $workspace := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.workspace)) (deepCopy (default dict $instance.workspace)) -}}
{{- $session := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.session)) (deepCopy (default dict $instance.session)) -}}
{{- $globalAuth := default dict $.Values.global.auth -}}
{{- $instanceAuth := default dict $instance.auth -}}
{{- $auth := mergeOverwrite (dict) (deepCopy $globalAuth) (deepCopy $instanceAuth) -}}
{{- if not (hasKey $seenGlobalEnvNamespaces $mainNamespace) }}
{{- $_ := set $seenGlobalEnvNamespaces $mainNamespace true -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.controlPlaneEnvConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
data:
{{- range $key := keys $.Values.global.controlPlaneEnv | sortAlpha }}
  {{ $key }}: {{ index $.Values.global.controlPlaneEnv $key | toString | quote }}
{{- end }}
---
{{- end }}
{{- $instanceEnv := mergeOverwrite (dict) (deepCopy (default dict $.Values.global.instanceEnv)) (deepCopy (default dict $instance.instanceEnv)) (deepCopy (default dict $instance.controlPlaneEnv)) -}}
{{- $usesManagedInstanceSecret := and (not $instanceAuth.existingSecretName) (gt (len $instanceAuth) 0) -}}
{{- $usesManagedSharedSecret := and (eq (len $instanceAuth) 0) (not $globalAuth.existingSecretName) -}}
{{- $globalControlPlaneEnv := default dict $.Values.global.controlPlaneEnv -}}
{{- if and (not (hasKey $globalControlPlaneEnv "GH_GITHUB_TOKEN_FILE")) (not (hasKey $instanceEnv "GH_GITHUB_TOKEN_FILE")) (or (and $usesManagedInstanceSecret (ne (default "" $auth.ghGithubToken) "")) (and $usesManagedSharedSecret (ne (default "" $globalAuth.ghGithubToken) ""))) }}
{{- $_ := set $instanceEnv "GH_GITHUB_TOKEN_FILE" "/var/run/control-plane-auth/gh-github-token" -}}
{{- end }}
{{- if and (not (hasKey $globalControlPlaneEnv "GH_HOSTS_YML_FILE")) (not (hasKey $instanceEnv "GH_HOSTS_YML_FILE")) (or (and $usesManagedInstanceSecret (ne (default "" $auth.ghHostsYml) "")) (and $usesManagedSharedSecret (ne (default "" $globalAuth.ghHostsYml) ""))) }}
{{- $_ := set $instanceEnv "GH_HOSTS_YML_FILE" "/var/run/control-plane-auth/gh-hosts.yml" -}}
{{- end }}
{{- $_ := set $instanceEnv "CONTROL_PLANE_K8S_NAMESPACE" $mainNamespace -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_NAMESPACE" $jobNamespace -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_COPILOT_SESSION_PVC" (include "control-plane.sessionClaimName" $ctx) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH" ($session.ghSubPath | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH" ($session.sshSubPath | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_WORKSPACE_SUBPATH" ($workspace.subPath | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT" (include "control-plane.execServiceAccountName" $ctx) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_SERVICE_ACCOUNT" (include "control-plane.jobServiceAccountName" $ctx) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_WORKSPACE_PVC" (include "control-plane.workspaceClaimName" $ctx) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_IMAGE" (include "control-plane.imageRef" (dict "image" $image)) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_HOST" (printf "%s.%s.svc.%s" (include "control-plane.serviceName" $ctx) $mainNamespace $.Values.global.clusterDomain) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_TRANSFER_PORT" ($service.port | toString) -}}
{{- $_ := set $instanceEnv "CONTROL_PLANE_JOB_IMAGE_PULL_POLICY" ($image.pullPolicy | toString) -}}
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
{{- if $instance.controlPlaneConfigJson }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.controlPlaneConfigConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
data:
  copilot-config.json: |{{ $instance.controlPlaneConfigJson | nindent 4 }}
---
{{- else if not (hasKey $seenGlobalConfigNamespaces $mainNamespace) }}
{{- $_ := set $seenGlobalConfigNamespaces $mainNamespace true -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "control-plane.sharedControlPlaneConfigConfigMapName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
data:
  copilot-config.json: |{{ $.Values.global.controlPlaneConfigJson | nindent 4 }}
---
{{- end }}
{{- end }}
