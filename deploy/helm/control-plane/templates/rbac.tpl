{{- $seenMainNamespaces := dict -}}
{{- $seenJobNamespaces := dict -}}
{{- $seenNamespacePairs := dict -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "control-plane.storageClassesClusterRoleName" (dict "root" $) }}
  labels:{{ include "control-plane.releaseLabels" (dict "root" $) | nindent 4 }}
rules:
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["list"]
---
{{- range $instance := .Values.instances }}
{{- $ctx := dict "root" $ "instance" $instance -}}
{{- $mainNamespace := include "control-plane.instanceMainNamespace" $ctx -}}
{{- $jobNamespace := include "control-plane.instanceJobNamespace" $ctx -}}
{{- $namespacePairKey := printf "%s/%s" $mainNamespace $jobNamespace -}}
{{- if not (hasKey $seenMainNamespaces $mainNamespace) }}
{{- $_ := set $seenMainNamespaces $mainNamespace true -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "control-plane.execPodsRoleName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
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
kind: RoleBinding
metadata:
  name: {{ include "control-plane.execPodsRoleName" $ctx }}
  namespace: {{ $mainNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
    namespace: {{ $mainNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "control-plane.execPodsRoleName" $ctx }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "control-plane.storageClassesClusterRoleBindingName" $ctx }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
    namespace: {{ $mainNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "control-plane.storageClassesClusterRoleName" $ctx }}
---
{{- end }}
{{- if not (hasKey $seenJobNamespaces $jobNamespace) }}
{{- $_ := set $seenJobNamespaces $jobNamespace true -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "control-plane.jobsRoleName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
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
  name: {{ include "control-plane.jobSelfReadRoleName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "control-plane.execWorkloadsRoleName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
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
  name: {{ include "control-plane.jobSelfReadRoleName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.jobServiceAccountName" $ctx }}
    namespace: {{ $jobNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "control-plane.jobSelfReadRoleName" $ctx }}
---
{{- end }}
{{- if not (hasKey $seenNamespacePairs $namespacePairKey) }}
{{- $_ := set $seenNamespacePairs $namespacePairKey true -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "control-plane.jobsRoleBindingName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.controlPlaneServiceAccountName" $ctx }}
    namespace: {{ $mainNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "control-plane.jobsRoleName" $ctx }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "control-plane.execWorkloadsRoleBindingName" $ctx }}
  namespace: {{ $jobNamespace }}
  labels:{{ include "control-plane.sharedLabels" $ctx | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "control-plane.execServiceAccountName" $ctx }}
    namespace: {{ $mainNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "control-plane.execWorkloadsRoleName" $ctx }}
---
{{- end }}
{{- end }}
