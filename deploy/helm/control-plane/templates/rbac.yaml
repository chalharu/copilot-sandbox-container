{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-exec-pods
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-jobs
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-job-self-read
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-exec-workloads
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-exec-pods
  namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
    namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-exec-pods
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-jobs
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
    namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-jobs
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-job-self-read
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.jobServiceAccountName" $ctx }}
    namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-job-self-read
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-exec-workloads
  namespace: {{ include "control-plane.instanceJobNamespace" $ctx }}
  labels:{{ include "control-plane.commonLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.execServiceAccountName" $ctx }}
    namespace: {{ include "control-plane.instanceMainNamespace" $ctx }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-exec-workloads
---
{{- end }}
