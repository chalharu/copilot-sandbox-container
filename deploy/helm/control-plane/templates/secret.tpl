{{- $seenGlobalAuthNamespaces := dict -}}
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $globalAuth := default dict $.Values.global.auth -}}
{{- $instanceAuth := default dict $instance.auth -}}
{{- $auth := mergeOverwrite (dict) $globalAuth $instanceAuth -}}
{{- if and (not $instanceAuth.existingSecretName) (gt (len $instanceAuth) 0) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "control-plane.authSecretName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
type: Opaque
stringData:
  ssh-public-key: |{{ $auth.sshPublicKey | nindent 4 }}
{{- if $auth.ghGithubToken }}
  gh-github-token: {{ $auth.ghGithubToken | quote }}
{{- end }}
{{- if $auth.ghHostsYml }}
  gh-hosts.yml: |{{ $auth.ghHostsYml | nindent 4 }}
{{- end }}
{{- if $auth.copilotGithubToken }}
  copilot-github-token: {{ $auth.copilotGithubToken | quote }}
{{- end }}
---
{{- else if and (not $globalAuth.existingSecretName) (not (hasKey $seenGlobalAuthNamespaces $mainNamespace)) }}
{{- $_ := set $seenGlobalAuthNamespaces $mainNamespace true -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $globalAuth.name }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
type: Opaque
stringData:
  ssh-public-key: |{{ $globalAuth.sshPublicKey | nindent 4 }}
{{- if $globalAuth.ghGithubToken }}
  gh-github-token: {{ $globalAuth.ghGithubToken | quote }}
{{- end }}
{{- if $globalAuth.ghHostsYml }}
  gh-hosts.yml: |{{ $globalAuth.ghHostsYml | nindent 4 }}
{{- end }}
{{- if $globalAuth.copilotGithubToken }}
  copilot-github-token: {{ $globalAuth.copilotGithubToken | quote }}
{{- end }}
---
{{- end }}
{{- end }}
