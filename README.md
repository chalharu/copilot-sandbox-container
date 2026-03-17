# copilot-sandbox-container

`copilot-sandbox-container` は、Copilot CLI 向けの Control Plane イメージ、
用途別の Execution Plane 参照実装、それらを lint / build / test / publish する
スクリプト群をまとめたリポジトリです。

まず全体像を掴みたい場合は、次を先に読むと迷いにくくなります。

- 要件と契約: `docs/requirements.md`
- Kubernetes 配備の詳細: `docs/kubernetes-deployment.md`
- 変更ルール: `CONTRIBUTING.md`
- `control-plane-run` の使い分け: `containers/control-plane/skills/control-plane-operations/references/control-plane-run.md`

## 概要

このリポジトリは、次の 2 層を前提にしています。

- **Control Plane**: Copilot CLI、`gh`、`git`、`kubectl`、rootless Podman wrapper、
  SSH、GNU Screen をまとめた長寿命の操作面
- **Execution Plane**: 実際の build / test / lint / 実行を担当する用途別コンテナ

設計上の基本方針は次のとおりです。

- Control Plane は、単独起動環境と Kubernetes 環境でできるだけ同じ運用感を保つ
- 短時間で局所的な処理は local Podman 系、長時間または信頼性を優先する処理は
  Kubernetes Job に寄せる
- サンプルの least-privilege Kubernetes Deployment では、
  `CONTROL_PLANE_RUN_MODE=k8s-job` を既定にして Job 実行を主経路にする
- サンプルの Kubernetes Deployment では `spec.hostUsers: false` を設定し、
  Pod user namespace を有効にして local rootless Podman の成立可能性を上げる
- local nested Podman / Kind は best-effort であり、outer runtime の制約を越えて
  完全保証はしない

## リポジトリに含まれるもの

### 公開イメージ

- `ghcr.io/chalharu/copilot-sandbox-container/control-plane`
- `ghcr.io/chalharu/copilot-sandbox-container/yamllint`

### リポジトリ内のイメージ定義

- `containers/control-plane/`: Control Plane イメージ
- `containers/yamllint/`: `yamllint` v1.38.0 用の最小イメージ
- `containers/execution-plane-smoke/`: smoke test 用の最小 Execution Plane
- `containers/execution-plane-rust/`: Rust 向け参照実装
- `containers/execution-plane-python/`: Python 向け参照実装
- `containers/execution-plane-go/`: Go 向け参照実装
- `containers/execution-plane-node/`: Node.js 向け参照実装

### 主要スクリプト

- `scripts/lint.sh`: `hadolint` / `shellcheck` / `biome` / `yamllint` と Renovate 設定検証
- `scripts/build-test.sh`: build / standalone smoke / Kind integration
- `scripts/test-standalone.sh`: 単独起動モードの下位 smoke test
- `scripts/test-kind.sh`: Kind 上の下位 integration test

### 配備例

- `deploy/kubernetes/control-plane.example.yaml`
- `docs/kubernetes-deployment.md`

## クイックスタート

### lint

```bash
./scripts/lint.sh
```

Podman 系を明示したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh
```

`scripts/lint.sh` は、`hadolint` / `shellcheck` / `biome` を trusted upstream image で実行し、
`yamllint` はこのリポジトリの `containers/yamllint/` を build して使います。

### build / test

```bash
./scripts/build-test.sh
```

系統を固定したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

`scripts/build-test.sh` は `docker buildx` を優先し、使えない場合に Podman 系へ
フォールバックします。Buildah は host / CI 側に既にある場合だけ利用し、
Control Plane イメージ自体には同梱しません。内部では
`containers/control-plane` と `containers/execution-plane-smoke` を build し、
`scripts/test-standalone.sh` と `scripts/test-kind.sh` を順に呼び出します。

### `control-plane-run` の典型パターン

短いローカル実行:

```bash
control-plane-run --mode auto --execution-hint short \
  --workspace /workspace \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/short.txt short
```

Kubernetes Job 実行:

```bash
control-plane-run --mode auto --execution-hint long \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long
```

小さい補助ファイルを Job に渡す:

```bash
control-plane-run --mode k8s-job \
  --namespace copilot-sandbox-jobs \
  --mount-file ./script.sh:scripts/script.sh \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke exec bash -lc \
     'bash /var/run/control-plane/job-inputs/scripts/script.sh'
```

サンプルの Kubernetes Deployment では `CONTROL_PLANE_RUN_MODE=k8s-job` と
`CONTROL_PLANE_JOB_NAMESPACE=copilot-sandbox-jobs` を設定しているため、
オプションを付けない `control-plane-run ...` でも Job 経路へ寄ります。local Podman を明示したいときだけ
`--mode podman` または `CONTROL_PLANE_RUN_MODE=auto` を使ってください。

## Rootless Podman / nested runtime の扱い

Control Plane イメージ内の `/usr/local/bin/podman` と `/usr/local/bin/docker` は、
どちらも `control-plane-podman` wrapper への symlink です。これは rootless Podman の
失敗に対して、outer runtime 側が原因であることを分かりやすく補足するためです。

たとえば `podman pull hello-world:latest` で次のようなエラーが出る場合:

- `cannot clone: Operation not permitted`
- `invalid internal status ... cannot re-exec process`
- `cannot set user namespace`

`control-plane-podman` wrapper は `invalid internal status ... podman system migrate` を含む
stale state を見つけると、`podman system migrate` を 1 回だけ自動で試します。それでも
失敗する場合は、次の原因を疑ってください。

多くは **Pod 内設定と outer host / runtime 制約の組み合わせ** が原因です。まず sample manifest
どおりに `spec.hostUsers: false` で Pod user namespace を有効化したうえで、次の点に注意してください。

- `SETFCAP` のような capability の再追加は Linux 5.12+ では必要になり得るが、それだけでは不十分
- sample manifest では `spec.hostUsers: false` を設定し、Kubernetes Pod user namespace を明示的に使う
- outer runtime 側で nested user namespaces、`newuidmap` / `newgidmap`、
  必要な seccomp / AppArmor / sysctl、状況によっては `/dev/fuse` も許可されている必要がある
- `securityContext.privileged: true` でも outer runtime が user namespace を禁止していれば失敗する

そのため、Kubernetes 上では local nested Podman / Kind を best-effort 扱いにしています。
詰まった場合は、次のいずれかへ切り替えてください。

- `control-plane-run --mode k8s-job`
- GitHub Actions
- rootless Podman が正しく動く host runner

どうしても Pod 内ローカル実行を優先したい場合だけ、
`CONTROL_PLANE_RUN_MODE=auto` へ切り替えるか `control-plane-run --mode podman` を使ってください。

Podman storage は driver ごとに分離しています。

- overlay: `~/.copilot/containers/overlay/storage`
- vfs: `~/.copilot/containers/vfs/storage`

これにより、`/dev/fuse` の有無や securityContext の違いで overlay / vfs が切り替わっても、
DB の衝突を起こしにくくしています。Podman 系では Kind 内の image 名と合わせるため、
既定の image tag に `localhost/` 接頭辞を使います。

## Kubernetes 配備

Kubernetes 配備の詳細とサンプル manifest の前提は `docs/kubernetes-deployment.md` にまとめています。
ここでは最初に把握しておきたい点だけを抜き出します。

### 配備の要点

- テンプレート: `deploy/kubernetes/control-plane.example.yaml`
- 既定 namespace: Control Plane は `copilot-sandbox`、Job は `copilot-sandbox-jobs`
- 構成: Secret / Service / Deployment / PVC をまとめた単一レプリカ構成
- `spec.hostUsers: false` を設定し、Pod user namespace を使う
- SSH 公開鍵は Secret から渡し、必要なら `COPILOT_GITHUB_TOKEN` も同じ Secret で注入できる
- `COPILOT_GITHUB_TOKEN` は login shell へ export せず、Copilot 起動時だけ
  `--secret-env-vars=COPILOT_GITHUB_TOKEN` 経由で渡す
- `CONTROL_PLANE_GIT_USER_NAME` / `CONTROL_PLANE_GIT_USER_EMAIL` を env に入れると、
  entrypoint が `~/.gitconfig` と GitHub credential helper を事前設定する
- SSH host key は PVC 上に永続化されるため、Pod の再作成でも fingerprint が変わりにくい

### セキュリティとセッションの既定値

サンプル Deployment は containerd でも使いやすい least-privilege の SSH / Copilot
プロファイルを既定にしています。

- Pod `securityContext.fsGroup: 1000`
- container `allowPrivilegeEscalation: true`
- container `capabilities.drop: [ALL]`
- container `capabilities.add: [CHOWN, DAC_OVERRIDE, FOWNER, SETFCAP, SETGID, SETUID, SYS_CHROOT]`
- control-plane container `seccompProfile: Unconfined`
- Pod template annotation `container.apparmor.security.beta.kubernetes.io/control-plane: unconfined`

`allowPrivilegeEscalation` は `sshd` の privilege separation と entrypoint の root 操作のため
`true` のままです。local rootless Podman を `privileged: false` のまま通すには、
多くの runtime で control-plane container の `seccompProfile: Unconfined` も必要になります。
entrypoint は必要 capability が欠けている場合に、起動直後に明示的なエラーを出します。

さらに sample manifest は `spec.hostUsers: false` を入れています。これは root in Pod を
host 側の non-root UID/GID に map する Kubernetes Pod user namespace で、nested rootless
Podman が user namespace を切り直しやすくするための前提です。cluster 側が Pod user namespace
をサポートしていない場合は、Pod 自体が起動しないか、local Podman が引き続き失敗します。

対話的な SSH ログインでは GNU Screen の session picker が起動します。picker が
runtime 依存の理由で失敗したときだけ通常の login shell にフォールバックし、
picker から入った Screen を終了したときは SSH もそのまま閉じます。Copilot セッションが無い場合は picker に
`Copilot (/workspace, --yolo)` が追加され、Enter だけで `/workspace` から
`copilot --yolo` を始められます。

### shell / terminal の既定値

- `EDITOR` / `VISUAL` は未設定時だけ `vim`
- `GH_PAGER=cat`
- login shell では `LANG=C.UTF-8` を補い、使えない `TERM` は `xterm-256color` / `xterm` へ補正し、イメージ側で `en_US.UTF-8` と `ja_JP.UTF-8` を生成
- GNU Screen は `screen-256color` / UTF-8 / background color erase / 10000 行 scrollback / mouse tracking を既定化
- `tmux-256color` や `xterm-256color` を含む追加 terminfo を同梱
- `control-plane-operations` skill をイメージに同梱し、起動時に `~/.copilot/skills/` へ同期

Copilot CLI の multiline 入力 (`Shift+Enter`) は upstream では Kitty protocol 対応 terminal を
前提とします。対応 terminal では `/terminal-setup` を実行してください。`tmux` / GNU Screen
越しでは key event が転送されず、`Shift+Enter` や `Ctrl+Enter` が安定しない場合があります。
その場合は paste か `Ctrl+G` を使ってください。

### Job に `/workspace` を見せる方法

Job namespace を分けたまま `/workspace` を共有したい場合は、Job namespace 側にも shared
storage を用意して `CONTROL_PLANE_JOB_WORKSPACE_PVC` を設定してください。小さい補助ファイル
だけで足りる場合は `control-plane-run --mount-file ...` で ConfigMap 経由にできます。

## イメージ方針と公開

- 契約を満たす trusted upstream image がある場合は、それをそのまま使う
- third-party image しかない、またはこのリポジトリ専用の薄い調整が必要な場合だけ
  リポジトリ内で最小イメージを build する
- そのようなリポジトリ管理イメージは GHCR に公開して再利用する

現時点の GHCR 公開対象:

- `control-plane`
- `yamllint`

`main` への push が成功すると、GitHub Actions は x64 / arm64 の matrix で lint / build / test
を実行し、その結果を使って
`ghcr.io/chalharu/copilot-sandbox-container/<image>` に multi-arch manifest を公開します。
公開 tag は `latest`、commit SHA、同梱ツールの version tag です。

- `control-plane`: `copilot-<COPILOT_CLI_VERSION>`
- `yamllint`: `<YAMLLINT_VERSION>`

version tag は「どのツール version を同梱しているか」を示す利便用です。厳密な再現性が必要な場合は、
引き続き commit SHA tag を使ってください。GitHub Actions は古い GHCR package version を
自動削除し、各イメージにつき直近 30 version を保持します。`containers/yamllint/` の
DHI base image pull と Renovate dry-run の registry 認証には
`DOCKERHUB_USERNAME` と `DOCKERHUB_TOKEN` を使います。

## Execution Plane について

同梱している Execution Plane は、Control Plane 連携を確認するための参照実装です。
一覧を固定することが目的ではありません。`/workspace` 共有や、対象 workflow に必要な
コマンド群まで含めて契約を満たす upstream イメージがあるなら、それを直接使って構いません。
不足がある場合だけ、薄いラッパーイメージを用意します。

より細かい挙動を確認したい場合だけ、下位の `scripts/test-standalone.sh` /
`scripts/test-kind.sh` を直接使ってください。

## トラブルシュート

### `podman pull hello-world:latest` が失敗する

`cannot clone: Operation not permitted` や `cannot re-exec process` は、outer runtime が
nested rootless Podman を止めているときの典型例です。まず `cat /proc/self/uid_map` で
Pod user namespace が有効か確認し、sample manifest の `spec.hostUsers: false` が入っているかを
見てください。そのうえでまだ失敗するなら、outer runtime 側の userns / `newuidmap` /
`newgidmap` / seccomp / AppArmor 条件が足りていません。sample manifest の
control-plane container は `seccompProfile: Unconfined` と AppArmor の unconfined annotation を前提にしています。`control-plane-run --mode k8s-job` または
GitHub Actions / host runner へ切り替えてください。

### `drop: ALL` にしたら SSH できない

`capabilities.add` に `CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `SETGID` / `SETUID` /
`SYS_CHROOT` を戻してください。`SETFCAP` は local rootless Podman 向けです。

### `LoadBalancer` の `EXTERNAL-IP` がまだ付かない

次で同じ Service 経由の SSH を使えます。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
```

### Copilot CLI の multiline shortcut が安定しない

Kitty protocol 対応 terminal では `/terminal-setup` を実行してください。`tmux` /
GNU Screen 越しでは paste か `Ctrl+G` を使うほうが安定します。
