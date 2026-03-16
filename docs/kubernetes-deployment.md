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
- PVC 上に永続化される SSH host key

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
4. テンプレートは同じ PVC の `ssh-host-keys` subPath に SSH host key を置くため、
   Pod が再作成されても host key が変わりません。
5. 必要に応じて Job 用の image pull policy と resource 上限を調整します。
6. 適用後は `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
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

対話的な SSH ログインでは、GNU Screen の既存セッション一覧と `New session`
を選べる picker が起動します。新しい作業を始めるときも、既存セッションへ
戻るときも同じ入口を使えます。

Control Plane イメージは `vim` を同梱し、ログイン shell で `EDITOR` /
`VISUAL` を未設定時だけ `vim` に補います。Copilot CLI で multiline shortcut が
通らないときでも、`Ctrl+G` ですぐ外部 editor を開けます。

同じ login shell では `GH_PAGER=cat` も既定化しており、`gh` の pager 待ちで
コマンドが止まって見える状況を避けます。あわせて `LANG` / `LC_*` も SSH client
から受け取れ、client が送らない場合は login shell で `LANG=C.UTF-8` を補うため、
日本語を含む UTF-8 テキストも表示しやすくしています。

また、GNU Screen では `screen-256color` / UTF-8 / alt screen / background color
erase を既定化し、`tmux-256color` を含む terminfo も入れています。そのため、
`tmux` 経由で SSH 接続しても表示崩れを起こしにくくしています。

ただし、Kubernetes 上の非特権 Pod では nested rootless Podman が host 側の
user namespace 制約で失敗し、`newuidmap ... Operation not permitted` が出る
場合があります。Control Plane イメージは `control-plane-run` 用の wrapper は
持ちますが、`scripts/lint.sh` や `scripts/build-test.sh` を完結させる nested
build runner までは持ちません。その場合は Control Plane 内で Podman を無理に
使わず、Docker Buildx が使える host か GitHub Actions で lint / build / test を
実行してください。Buildah を個別に使いたい場合は `quay.io/buildah/stable` のような
upstream イメージを host / CI 側で利用してください。

ただし Copilot CLI の multiline 入力 (`Shift+Enter`) 自体は upstream で Kitty
protocol 対応 terminal を前提としており、対応 terminal では `/terminal-setup`
を実行してください。`tmux` / GNU Screen を挟むと `Shift+Enter` や `Ctrl+Enter`
が安定しない場合があります。その場合は paste か `Ctrl+G` を使ってください。

`control-plane-operations` skill は Control Plane イメージに user-level skill として
同梱され、起動時に `~/.copilot/skills/control-plane-operations` へ同期されます。
そのため、このリポジトリ以外を `/workspace` に mount しても同じ運用ガイドを
使えます。repo 固有の追加 skill が必要な場合だけ、別途その repo 側に
`.github/skills/` を置いてください。

## private registry を使う場合

Execution Plane イメージを private registry から pull する場合は、
Kubernetes の imagePullSecrets に加えて、Control Plane の Deployment 側でも Podman の
認証情報を永続化しておくと運用しやすくなります。

- Kubernetes Job pull 用: Deployment / Job に `imagePullSecrets` を設定
- Control Plane の Podman pull 用: `~/.config/containers/auth.json` を永続化

`~/.config/containers/auth.json` を使う場合は、PVC もしくは Secret を
マウントして保持してください。
