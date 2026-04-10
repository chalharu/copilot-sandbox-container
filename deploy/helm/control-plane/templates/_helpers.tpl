{{- define "control-plane.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.releaseLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
helm.sh/chart: {{ include "control-plane.chart" .root | quote }}
{{- end -}}

{{- define "control-plane.instanceMainNamespace" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- default (default "copilot-sandbox" $root.Values.global.namespace) $instance.namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.instanceJobNamespace" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- default (default (printf "%s-jobs" (include "control-plane.instanceMainNamespace" (dict "root" $root "instance" $instance))) $root.Values.global.jobNamespace) $instance.jobNamespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.instanceQualifiedName" -}}
{{- printf "%s-%s" .base .instance.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.explicitOrQualifiedName" -}}
{{- if .explicit -}}
{{- .explicit | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" .base "instance" .instance) -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.serviceName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalService := default dict $root.Values.global.service -}}
{{- $instanceService := default dict $instance.service -}}
{{- $service := mergeOverwrite (dict) $globalService $instanceService -}}
{{- include "control-plane.explicitOrQualifiedName" (dict "base" $service.name "explicit" $instanceService.name "instance" $instance) -}}
{{- end -}}

{{- define "control-plane.workspaceClaimName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalWorkspace := default dict $root.Values.global.workspace -}}
{{- $instanceWorkspace := default dict $instance.workspace -}}
{{- $workspace := mergeOverwrite (dict) $globalWorkspace $instanceWorkspace -}}
{{- $existingClaim := $workspace.existingClaim -}}
{{- if $existingClaim -}}
{{- $existingClaim | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "control-plane.explicitOrQualifiedName" (dict "base" $workspace.claimName "explicit" $instanceWorkspace.claimName "instance" $instance) -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.sessionClaimName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalSession := default dict $root.Values.global.session -}}
{{- $instanceSession := default dict $instance.session -}}
{{- if $instanceSession.existingClaim -}}
{{- $instanceSession.existingClaim | trunc 63 | trimSuffix "-" -}}
{{- else if $instanceSession.claimName -}}
{{- $instanceSession.claimName | trunc 63 | trimSuffix "-" -}}
{{- else if $globalSession.existingClaim -}}
{{- $globalSession.existingClaim | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $globalSession.claimName | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.sessionStateSubPath" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalSession := default dict $root.Values.global.session -}}
{{- $instanceSession := default dict $instance.session -}}
{{- if $instanceSession.stateSubPath -}}
{{- trimPrefix "/" (trimSuffix "/" $instanceSession.stateSubPath) -}}
{{- else -}}
{{- $prefix := default "instances" $globalSession.statePathPrefix -}}
{{- if $prefix -}}
{{- printf "%s/%s" (trimPrefix "/" (trimSuffix "/" $prefix)) $instance.name -}}
{{- else -}}
{{- $instance.name -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.authSecretName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalAuth := default dict $root.Values.global.auth -}}
{{- $instanceAuth := default dict $instance.auth -}}
{{- $auth := mergeOverwrite (dict) $globalAuth $instanceAuth -}}
{{- $existingSecret := $auth.existingSecretName -}}
{{- if $existingSecret -}}
{{- $existingSecret | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "control-plane.explicitOrQualifiedName" (dict "base" $auth.name "explicit" $instanceAuth.name "instance" $instance) -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.controlPlaneEnvConfigMapName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-env" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.instanceEnvConfigMapName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-instance-env" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.controlPlaneConfigConfigMapName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-config" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.deploymentName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.controlPlaneServiceAccountName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.execServiceAccountName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-exec" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.jobServiceAccountName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-job" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.execPodsRoleName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-exec-pods" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.jobsRoleName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-jobs" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.jobSelfReadRoleName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-job-self-read" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.execWorkloadsRoleName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-exec-workloads" "instance" .instance) -}}
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
{{ include "control-plane.releaseLabels" . }}
{{ include "control-plane.selectorLabels" . }}
{{- end -}}
