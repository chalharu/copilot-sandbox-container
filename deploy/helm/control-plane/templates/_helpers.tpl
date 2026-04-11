{{- define "control-plane.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.releaseLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
helm.sh/chart: {{ include "control-plane.chart" .root | quote }}
{{- end -}}

{{- define "control-plane.sharedLabels" -}}
app.kubernetes.io/name: control-plane
{{ include "control-plane.releaseLabels" . }}
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

{{- define "control-plane.acpServiceName" -}}
{{- $root := .root -}}
{{- $instance := .instance -}}
{{- $globalService := default dict $root.Values.global.acpService -}}
{{- $instanceService := default dict $instance.acpService -}}
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
{{- if $instanceAuth.existingSecretName -}}
{{- $instanceAuth.existingSecretName | trunc 63 | trimSuffix "-" -}}
{{- else if gt (len $instanceAuth) 0 -}}
{{- include "control-plane.explicitOrQualifiedName" (dict "base" $globalAuth.name "explicit" $instanceAuth.name "instance" $instance) -}}
{{- else if $globalAuth.existingSecretName -}}
{{- $globalAuth.existingSecretName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $globalAuth.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.controlPlaneEnvConfigMapName" -}}
control-plane-env
{{- end -}}

{{- define "control-plane.instanceEnvConfigMapName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-instance-env" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.sharedControlPlaneConfigConfigMapName" -}}
control-plane-config
{{- end -}}

{{- define "control-plane.controlPlaneConfigConfigMapName" -}}
{{- if .instance.controlPlaneConfigJson -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-config" "instance" .instance) -}}
{{- else -}}
{{- include "control-plane.sharedControlPlaneConfigConfigMapName" . -}}
{{- end -}}
{{- end -}}

{{- define "control-plane.deploymentName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane" "instance" .instance) -}}
{{- end -}}

{{- define "control-plane.webDeploymentName" -}}
{{- include "control-plane.instanceQualifiedName" (dict "base" "control-plane-web" "instance" .instance) -}}
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

{{- define "control-plane.execPodsRoleName" -}}
control-plane-exec-pods
{{- end -}}

{{- define "control-plane.jobsRoleName" -}}
control-plane-jobs
{{- end -}}

{{- define "control-plane.jobSelfReadRoleName" -}}
control-plane-job-self-read
{{- end -}}

{{- define "control-plane.execWorkloadsRoleName" -}}
control-plane-exec-workloads
{{- end -}}

{{- define "control-plane.jobsRoleBindingName" -}}
{{- printf "%s-%s" (include "control-plane.jobsRoleName" .) (include "control-plane.instanceMainNamespace" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.execWorkloadsRoleBindingName" -}}
{{- printf "%s-%s" (include "control-plane.execWorkloadsRoleName" .) (include "control-plane.instanceMainNamespace" .) | trunc 63 | trimSuffix "-" -}}
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

{{- define "control-plane.acpSelectorLabels" -}}
{{ include "control-plane.selectorLabels" . }}
app.kubernetes.io/component: acp
{{- end -}}

{{- define "control-plane.webSelectorLabels" -}}
{{ include "control-plane.selectorLabels" . }}
app.kubernetes.io/component: web
{{- end -}}

{{- define "control-plane.commonLabels" -}}
{{ include "control-plane.releaseLabels" . }}
{{ include "control-plane.selectorLabels" . }}
{{- end -}}

{{- define "control-plane.acpCommonLabels" -}}
{{ include "control-plane.commonLabels" . }}
app.kubernetes.io/component: acp
{{- end -}}

{{- define "control-plane.webCommonLabels" -}}
{{ include "control-plane.commonLabels" . }}
app.kubernetes.io/component: web
{{- end -}}
