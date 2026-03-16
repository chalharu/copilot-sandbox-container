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
   これらの tag は amd64 / arm64 を含む multi-arch manifest として公開されます。
2. `control-plane-auth` Secret の `ssh-public-key` を利用者の公開鍵に置き換えます。
   `copilot-github-token` は任意ですが、設定すると SSH ログイン後の shell でも
   `COPILOT_GITHUB_TOKEN` として利用できます。
3. `storageClassName` と PVC サイズをクラスタ環境に合わせて調整します。
4. テンプレートは同じ PVC の `ssh-host-keys` subPath に SSH host key を置くため、
   Pod が再作成されても host key が変わりません。
5. テンプレートは containerd でも使いやすい least-privilege の SSH / Copilot
   プロファイルを既定にしています。Pod では `securityContext.fsGroup: 1000` を
   使って projected service-account token を `copilot` shell から読めるようにし、
   main container では `privileged: false` のまま
   capability を `CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `SETGID` / `SETUID` /
   `SYS_CHROOT`
   に絞り、`seccompProfile: RuntimeDefault` を使います。`allowPrivilegeEscalation`
   は `sshd` の setuid/setgid・privilege separation sandbox と entrypoint の root
   操作のため `true` のままです。
6. 同時に `CONTROL_PLANE_RUN_MODE=k8s-job` を入れているため、SSH ログイン後の
   既定経路は Kubernetes Job 実行です。containerd のように `hostUsers: false` を
   使えない環境でも SSH / Copilot / `k8s-job-*` はそのまま利用できます。
7. local nested Podman / Kind は依然として best-effort です。`SETUID` /
   `SETGID` だけでは `newuidmap` / `newgidmap` の代替にはならず、outer host /
   runtime 側の user namespace 制約や `/dev/fuse` 提供状況も残ります。Pod 内で
   `scripts/lint.sh` / `scripts/build-test.sh` を直接回したい場合は host か
   GitHub Actions を使ってください。どうしても Pod 内ローカル実行を優先したい
   場合だけ、追加 device / capability か `securityContext.privileged: true` を
   opt-in してください。
8. 必要に応じて Job 用の image pull policy と resource 上限を調整します。
9. 適用後は `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
   のように Service 経由で SSH を公開できます。

```yaml
securityContext:
  fsGroup: 1000
...
container securityContext:
  privileged: false
  runAsUser: 0
  runAsNonRoot: false
  allowPrivilegeEscalation: true
  capabilities:
    drop:
      - ALL
    add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
      - SYS_CHROOT
  seccompProfile:
    type: RuntimeDefault
...
- name: CONTROL_PLANE_RUN_MODE
  value: k8s-job
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
を選べる picker が起動します。既存の Copilot セッションが無い場合は
`Copilot (/workspace, --yolo)` も追加され、Enter だけで `/workspace` から
`copilot --yolo` を始められます。Copilot 用 session は detached ではなく SSH TTY
に直接 attach した状態で起動するため、接続直後に応答が止まったように見えにくく、
起動メッセージもそのまま確認できます。新しい作業を始めるときも、既存セッションへ
戻るときも同じ入口を使えます。

Control Plane イメージは `vim` を同梱し、ログイン shell で `EDITOR` /
`VISUAL` を未設定時だけ `vim` に補います。Copilot CLI で multiline shortcut が
通らないときでも、`Ctrl+G` ですぐ外部 editor を開けます。

同じ login shell では `GH_PAGER=cat` も既定化しており、`gh` の pager 待ちで
コマンドが止まって見える状況を避けます。あわせて `LANG` / `LC_*` も SSH client
から受け取れ、client が送らない場合は login shell で `LANG=C.UTF-8` を補います。
イメージ側では `en_US.UTF-8` と `ja_JP.UTF-8` も生成してあるため、
`LC_ALL=en_US.UTF8` のような locale でも warning を出しにくく、日本語を含む
UTF-8 テキストも表示しやすくしています。

また、GNU Screen では `screen-256color` / UTF-8 / alt screen / background color
erase を既定化し、`tmux-256color` を含む terminfo も入れています。そのため、
`tmux` 経由で SSH 接続しても表示崩れを起こしにくくしています。

このサンプルでは containerd でも成立する SSH / Copilot 用の最小権限を主軸にして
います。Pod の `fsGroup: 1000` で projected service-account token を `copilot`
user から読めるようにしたうえで、`allowPrivilegeEscalation` は `sshd` の
setuid/setgid と entrypoint の root 操作のため `true` のままにし、capability は
`CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `SETGID` / `SETUID` / `SYS_CHROOT`
に絞っています。`SYS_CHROOT` は sshd の privilege separation sandbox が pre-auth
child を chroot するために必要です。

一方で local Podman / Kind は別問題で、`SETUID` / `SETGID` だけでも
`newuidmap` / `newgidmap` の代替にはなりません。outer host / container runtime
側で user namespace や `/dev/fuse` が許可されていない場合は、この構成でも
失敗します。その場合は GitHub Actions / host runner を使うか、必要なときだけ
追加 privilege を opt-in してください。containerd では `hostUsers: false` を
前提にできないため、サンプルの既定値からも外しています。

### Podman storage 初期化

Control Plane は起動時に Podman 用 `graphroot` / `runroot` を
`~/.copilot/containers/storage` と `~/.copilot/run/containers/storage` へ固定し、
`storage/overlay` / `storage/volumes` を先に作ります。これにより、
`/state/copilot/containers/storage/overlay/...` で `No such file or directory`
が出る初期化レースを起こしにくくしています。

それでもクラスタ側が privileged Pod を禁止していたり、外側の host / container
runtime 側が user namespace や `newuidmap` / `newgidmap` を止めている場合は、
`newuidmap ... Operation not permitted` が出ることがあります。その場合は Pod
Security / runtime 設定を見直すか、Control Plane 内で Podman を無理に使わず、
Docker Buildx が使える host か GitHub Actions で lint / build / test を実行して
ください。Buildah を個別に使いたい場合は `quay.io/buildah/stable` のような
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
