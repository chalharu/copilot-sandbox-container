{{- define "control-plane.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.instanceMainNamespace" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- default (printf "%s-%s" $root.Values.global.namespacePrefix $instance.name) $instance.namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.instanceJobNamespace" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- default (printf "%s-jobs" (include "control-plane.instanceMainNamespace" (dict "root" $root "instance" $instance))) $instance.jobNamespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.serviceName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $service := mergeOverwrite (dict) $root.Values.global.service (default dict $instance.service) -}}
{{- $service.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.workspaceClaimName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $workspace := mergeOverwrite (dict) $root.Values.global.workspace (default dict $instance.workspace) -}}
{{- $existingClaim := $workspace.existingClaim -}}
{{- if $existingClaim -}}
{{- $existingClaim | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $workspace.claimName | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.sessionClaimName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $session := mergeOverwrite (dict) $root.Values.global.session (default dict $instance.session) -}}
{{- $existingClaim := $session.existingClaim -}}
{{- if $existingClaim -}}
{{- $existingClaim | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $session.claimName | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.authSecretName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $auth := mergeOverwrite (dict) $root.Values.global.auth (default dict $instance.auth) -}}
{{- $existingSecret := $auth.existingSecretName -}}
{{- if $existingSecret -}}
{{- $existingSecret | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $auth.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.controlPlaneEnvConfigMapName" -}}
control-plane-env
{{- end -}}

{{- define "control-plane.instanceEnvConfigMapName" -}}
control-plane-instance-env
{{- end -}}

{{- define "control-plane.controlPlaneConfigConfigMapName" -}}
control-plane-config
{{- end -}}

{{- define "control-plane.controlPlaneServiceAccountName" -}}
control-plane
{{- end -}}

{{- define "control-plane.execServiceAccountName" -}}
control-plane-exec
{{- end -}}

{{- define "control-plane.jobServiceAccountName" -}}
control-plane-job
{{- end -}}

{{- define "control-plane.imageRef" -}}
{{- $image := .image -}}
{{- $digest := dig "digest" "" $image -}}
{{- if $digest -}}
{{- printf "%s@%s" $image.repository $digest -}}
{{- else -}}
{{- printf "%s:%s" $image.repository (default "latest" $image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.selectorLabels" -}}
app.kubernetes.io/name: control-plane
control-plane.github.com/instance: {{ .instance.name | quote }}
{{- end -}}

{{- define "control-plane.commonLabels" -}}
{{ include "control-plane.selectorLabels" . }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
helm.sh/chart: {{ include "control-plane.chart" .root | quote }}
{{- end -}}
