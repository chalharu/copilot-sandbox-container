{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $image := mergeOverwrite (dict) $.Values.global.image (default dict $instance.image) -}}
{{- $workspace := mergeOverwrite (dict) $.Values.global.workspace (default dict $instance.workspace) -}}
{{- $session := mergeOverwrite (dict) $.Values.global.session (default dict $instance.session) -}}
{{- $sessionStateSubPath := include "control-plane.sessionStateSubPath" $ctx -}}
{{- $resources := mergeOverwrite (dict) $.Values.global.resources (default dict $instance.resources) -}}
{{- $deploymentAnnotations := mergeOverwrite (dict) $.Values.global.deploymentAnnotations (default dict $instance.deploymentAnnotations) -}}
{{- $podAnnotations := mergeOverwrite (dict) $.Values.global.podAnnotations (default dict $instance.podAnnotations) -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "control-plane.deploymentName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
{{- if $deploymentAnnotations }}
  annotations:
{{- range $key := keys $deploymentAnnotations | sortAlpha }}
    {{ $key }}: {{ index $deploymentAnnotations $key | toString | quote }}
{{- end }}
{{- end }}
spec:
  replicas: {{ default 1 $instance.replicaCount }}
  strategy:
    type: Recreate
  selector:
    matchLabels:{{ include "control-plane.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:{{ include "control-plane.commonLabels" $ctx | nindent 8 }}
{{- if $podAnnotations }}
      annotations:
{{- range $key := keys $podAnnotations | sortAlpha }}
        {{ $key }}: {{ index $podAnnotations $key | toString | quote }}
{{- end }}
{{- end }}
    spec:
      securityContext:
        fsGroup: 1000
      serviceAccountName: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
{{- if $instance.imagePullSecrets }}
      imagePullSecrets:{{ toYaml $instance.imagePullSecrets | nindent 8 }}
{{- else if $.Values.global.imagePullSecrets }}
      imagePullSecrets:{{ toYaml $.Values.global.imagePullSecrets | nindent 8 }}
{{- end }}
      initContainers:
        - name: init-state-dirs
          image: busybox:1.37.0@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              mkdir -p \
                /copilot-session/{{ $session.ghSubPath }} \
                /copilot-session/{{ $session.sshSubPath }} \
                /copilot-session/{{ $sessionStateSubPath }}/state/ssh-auth \
                /copilot-session/{{ $sessionStateSubPath }}/state/ssh-host-keys \
                /copilot-session/{{ $sessionStateSubPath }}/session-state \
                /workspace-state/{{ $workspace.subPath }} \
                /cache/runtime-tmp
              touch \
                /copilot-session/{{ $sessionStateSubPath }}/state/copilot-config.json \
                /copilot-session/{{ $sessionStateSubPath }}/state/command-history-state.json
              chown -R 1000:1000 \
                /copilot-session/{{ $sessionStateSubPath }}/state \
                /copilot-session/{{ $sessionStateSubPath }}/session-state \
                /copilot-session/{{ $session.ghSubPath }} \
                /copilot-session/{{ $session.sshSubPath }}
              find \
                /copilot-session/{{ $sessionStateSubPath }}/state \
                /copilot-session/{{ $sessionStateSubPath }}/session-state \
                /copilot-session/{{ $session.ghSubPath }} \
                /copilot-session/{{ $session.sshSubPath }} \
                -type d -exec chmod 700 {} +
              find \
                /copilot-session/{{ $sessionStateSubPath }}/state \
                /copilot-session/{{ $sessionStateSubPath }}/session-state \
                /copilot-session/{{ $session.ghSubPath }} \
                /copilot-session/{{ $session.sshSubPath }} \
                -type f -exec chmod 600 {} +
              chown 1000:1000 /workspace-state/{{ $workspace.subPath }}
              chmod 700 /workspace-state/{{ $workspace.subPath }}
              chown 0:1000 /cache/runtime-tmp
              chmod 755 /cache/runtime-tmp
          securityContext:
            privileged: false
            runAsUser: 0
            runAsGroup: 1000
            runAsNonRoot: false
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /copilot-session
            - name: workspace
              mountPath: /workspace-state
            - name: cache
              mountPath: /cache
        - name: init-state
          image: busybox:1.37.0@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              [ -s /state/copilot-config.json ] || cat > /state/copilot-config.json <<'JSON'
              {
                "telemetry": false
              }
              JSON
          securityContext:
            privileged: false
            runAsUser: 1000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /state
              subPath: {{ printf "%s/state" $sessionStateSubPath | quote }}
      containers:
        - name: control-plane
          image: {{ include "control-plane.imageRef" (dict "image" $image) }}
          imagePullPolicy: {{ $image.pullPolicy }}
          envFrom:
            - configMapRef:
                name: {{ include "control-plane.controlPlaneEnvConfigMapName" $ctx }}
            - configMapRef:
                name: {{ include "control-plane.instanceEnvConfigMapName" $ctx }}
          env:
            - name: CONTROL_PLANE_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: CONTROL_PLANE_POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: CONTROL_PLANE_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: CONTROL_PLANE_POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
            - name: CONTROL_PLANE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            privileged: false
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            capabilities:
              drop:
                - ALL
              add:
                - AUDIT_WRITE
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
                - KILL
                - SETGID
                - SETUID
                - SYS_CHROOT
            seccompProfile:
              type: RuntimeDefault
          ports:
            - containerPort: 2222
              name: ssh
          readinessProbe:
            exec:
              command:
                - bash
                - -lc
                - pgrep -x sshd >/dev/null
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec:
              command:
                - bash
                - -lc
                - pgrep -x sshd >/dev/null
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          resources:
{{ toYaml $resources | nindent 12 }}
          volumeMounts:
            - name: copilot-session
              mountPath: /home/copilot/.copilot/config.json
              subPath: {{ printf "%s/state/copilot-config.json" $sessionStateSubPath | quote }}
            - name: copilot-session
              mountPath: /home/copilot/.copilot/command-history-state.json
              subPath: {{ printf "%s/state/command-history-state.json" $sessionStateSubPath | quote }}
            - name: copilot-session
              mountPath: /home/copilot/.copilot/session-state
              subPath: {{ printf "%s/session-state" $sessionStateSubPath | quote }}
            - name: copilot-session
              mountPath: /home/copilot/.config/gh
              subPath: {{ $session.ghSubPath | quote }}
            - name: copilot-session
              mountPath: /home/copilot/.ssh
              subPath: {{ $session.sshSubPath | quote }}
            - name: copilot-session
              mountPath: /home/copilot/.config/control-plane/ssh-auth
              subPath: {{ printf "%s/state/ssh-auth" $sessionStateSubPath | quote }}
            - name: copilot-session
              mountPath: /var/lib/control-plane/ssh-host-keys
              subPath: {{ printf "%s/state/ssh-host-keys" $sessionStateSubPath | quote }}
            - name: workspace
              mountPath: /workspace
              subPath: {{ $workspace.subPath | quote }}
            - name: cache
              mountPath: /var/tmp/control-plane
              subPath: runtime-tmp
            - name: control-plane-auth
              mountPath: /var/run/control-plane-auth
              readOnly: true
            - name: control-plane-config
              mountPath: /var/run/control-plane-config
              readOnly: true
      volumes:
        - name: copilot-session
          persistentVolumeClaim:
            claimName: {{ include "control-plane.sessionClaimName" $ctx }}
        - name: workspace
          persistentVolumeClaim:
            claimName: {{ include "control-plane.workspaceClaimName" $ctx }}
        - name: cache
          emptyDir: {}
        - name: control-plane-auth
          secret:
            secretName: {{ include "control-plane.authSecretName" $ctx }}
        - name: control-plane-config
          configMap:
            name: {{ include "control-plane.controlPlaneConfigConfigMapName" $ctx }}
{{- if $instance.nodeSelector }}
      nodeSelector:{{ toYaml $instance.nodeSelector | nindent 8 }}
{{- else if $.Values.global.nodeSelector }}
      nodeSelector:{{ toYaml $.Values.global.nodeSelector | nindent 8 }}
{{- end }}
{{- if $instance.affinity }}
      affinity:{{ toYaml $instance.affinity | nindent 8 }}
{{- else if $.Values.global.affinity }}
      affinity:{{ toYaml $.Values.global.affinity | nindent 8 }}
{{- end }}
{{- if $instance.tolerations }}
      tolerations:{{ toYaml $instance.tolerations | nindent 8 }}
{{- else if $.Values.global.tolerations }}
      tolerations:{{ toYaml $.Values.global.tolerations | nindent 8 }}
{{- end }}
---
{{- end }}
