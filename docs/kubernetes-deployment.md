# Kubernetes deployment example

このドキュメントは、Control Plane を Kubernetes 上で動かすための
最小テンプレートを示します。

## 含まれるもの

- Namespace
- ServiceAccount
- Job 操作用 RBAC
- PersistentVolumeClaim
- Control Plane Pod

テンプレート本体は `deploy/kubernetes/control-plane.example.yaml` にあります。

## 使い方

1. `image` を実際の Control Plane イメージに置き換えます。
2. `SSH_PUBLIC_KEY` を利用者の公開鍵に置き換えます。
3. `storageClassName` と PVC サイズをクラスタ環境に合わせて調整します。
4. 必要に応じて Job 用の image pull policy と resource 上限を調整します。

```yaml
- name: CONTROL_PLANE_JOB_IMAGE_PULL_POLICY
  value: IfNotPresent
- name: CONTROL_PLANE_JOB_CPU_REQUEST
  value: 250m
- name: CONTROL_PLANE_JOB_CPU_LIMIT
  value: "2"
- name: CONTROL_PLANE_JOB_MEMORY_REQUEST
  value: 256Mi
- name: CONTROL_PLANE_JOB_MEMORY_LIMIT
  value: 2Gi
```

## private registry を使う場合

Execution Plane イメージを private registry から pull する場合は、
Kubernetes の imagePullSecrets に加えて、Control Plane 側でも Podman の
認証情報を永続化しておくと運用しやすくなります。

- Kubernetes Job pull 用: Pod / Job に `imagePullSecrets` を設定
- Control Plane の Podman pull 用: `~/.config/containers/auth.json` を永続化

`~/.config/containers/auth.json` を使う場合は、PVC もしくは Secret を
マウントして保持してください。
