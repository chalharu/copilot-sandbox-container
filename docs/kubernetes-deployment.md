# Kubernetes deployment example

このドキュメントは、Control Plane を Kubernetes 上で動かすための
最小テンプレートを示します。

## 含まれるもの

- Namespace
- ServiceAccount
- Job 操作用 RBAC
- SSH 公開鍵と任意の Copilot token 用 Secret
- PersistentVolumeClaim
- SSH 用 Service
- Control Plane Deployment

テンプレート本体は `deploy/kubernetes/control-plane.example.yaml` にあります。

## 使い方

1. `image` を利用したい Control Plane イメージに合わせます。GitHub Actions から
   公開される既定値は
   `ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest` です。
   `:copilot-<COPILOT_CLI_VERSION>` tag も使えますが、再現性を優先する場合は
   `:latest` ではなく commit SHA tag を使ってください。なお公開イメージは
   直近 30 version を保持し、それ以前の package version は自動削除されます。
2. `control-plane-auth` Secret の `ssh-public-key` を利用者の公開鍵に置き換えます。
   `copilot-github-token` は任意ですが、設定すると SSH ログイン後の shell でも
   `COPILOT_GITHUB_TOKEN` として利用できます。
3. `storageClassName` と PVC サイズをクラスタ環境に合わせて調整します。
4. 必要に応じて Job 用の image pull policy と resource 上限を調整します。
5. 適用後は `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
   のように Service 経由で SSH を公開できます。

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

`copilot-github-token` に入れる値は、GitHub Copilot CLI の自動化向け
`COPILOT_GITHUB_TOKEN` として使われます。GitHub Actions の既定
`GITHUB_TOKEN` ではなく、Copilot 利用権限を持つ fine-grained PAT を使ってください。

テンプレートでは raw Pod ではなく `Deployment` を採用しています。これにより
単一レプリカ構成のまま self-healing と更新管理を使え、`strategy: Recreate` で
単一の PVC を安全に持ち回せます。

## private registry を使う場合

Execution Plane イメージを private registry から pull する場合は、
Kubernetes の imagePullSecrets に加えて、Control Plane の Deployment 側でも Podman の
認証情報を永続化しておくと運用しやすくなります。

- Kubernetes Job pull 用: Deployment / Job に `imagePullSecrets` を設定
- Control Plane の Podman pull 用: `~/.config/containers/auth.json` を永続化

`~/.config/containers/auth.json` を使う場合は、PVC もしくは Secret を
マウントして保持してください。
