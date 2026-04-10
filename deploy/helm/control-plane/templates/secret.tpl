{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $auth := mergeOverwrite (dict) $.Values.global.auth (default dict $instance.auth) -}}
{{- if not $auth.existingSecretName }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "control-plane.authSecretName" $ctx }}
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
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
{{- end }}
{{- end }}
