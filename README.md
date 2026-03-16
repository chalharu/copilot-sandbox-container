# copilot-sandbox-container

Control Plane / Execution Plane の要件は `docs/requirements.md` にあります。

## 概要

このリポジトリは、Copilot 向けの `control-plane` イメージと、用途別の
Execution Plane 参照実装、それらを lint / build / test / publish する
スクリプト群をまとめたものです。

## 含まれるもの

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

- `scripts/lint.sh`: `hadolint` / `shellcheck` / `biome` / `yamllint` と Renovate 設定検証を実行
- `scripts/build-test.sh`: build / standalone smoke / Kind integration を実行
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

Podman 系を固定したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh
```

`scripts/lint.sh` は、信頼できる upstream イメージである
`hadolint` / `shellcheck` / `biome` は upstream image を直接使い、
`yamllint` についてはリポジトリ内の `containers/yamllint/` を build して使います。

### build / test

```bash
./scripts/build-test.sh
```

系統を明示したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

`scripts/build-test.sh` は `docker buildx` が利用可能なら Docker / BuildKit を使い、
それ以外では Podman 系へフォールバックします。Buildah は host / CI 側に既にある
場合だけ利用し、Control Plane イメージ自体には同梱しません。内部では
`containers/control-plane` と `containers/execution-plane-smoke` を build し、
`scripts/test-standalone.sh` と `scripts/test-kind.sh` を順に呼び出します。

Control Plane イメージには `podman` / `kind` など
`scripts/lint.sh` や `scripts/build-test.sh` に必要なコマンドを同梱しています。
ただし nested build runner が実際に動くかは、外側の host / container runtime /
Kubernetes securityContext 依存です。サンプルの Kubernetes Deployment は
containerd でも使いやすい least-privilege の SSH/Copilot プロファイルを既定にし、
Pod の `securityContext.fsGroup` を `1000` にして projected service-account token を
`copilot` shell から読めるようにしたうえで、
`privileged: false` のまま capability を `CHOWN` / `DAC_OVERRIDE` / `FOWNER` /
`SETGID` / `SETUID` / `SYS_CHROOT` に絞っています。`allowPrivilegeEscalation` は
`sshd` の setuid/setgid・privilege separation sandbox と entrypoint の root 操作の
ため `true` のままですが、
`CONTROL_PLANE_RUN_MODE=k8s-job` を入れて local nested Podman を既定経路から
外しています。

そのため、Kubernetes 上の既定構成では SSH / Copilot / `k8s-job-*` が主経路です。
`control-plane-run` を明示せず使っても Job 実行へ寄るため、containerd のように
`hostUsers: false` を使えない環境でも運用しやすくなっています。local nested
Podman / Kind は依然 best-effort で、outer runtime 側の user namespace、
`newuidmap` / `newgidmap`、`/dev/fuse` などが必要です。そこで詰まる場合は
GitHub Actions か host runner を使ってください。どうしても Pod 内ローカル実行を
優先したい場合だけ、追加 device / capability か
`securityContext.privileged: true` を opt-in してください。

Podman 系では Kind 内の image 名と一致させるため、デフォルトの tag に
`localhost/` 接頭辞を使います。

## イメージ方針

- 契約を満たす trusted upstream image がある場合は、それをそのまま使います。
- 使えるのが third-party image だけ、またはこのリポジトリ専用の薄い調整が必要な
  場合は、リポジトリ内で最小イメージを build します。
- そのようなリポジトリ管理イメージは GHCR に公開して再利用します。

現時点の GHCR 公開対象:

- `control-plane`
- `yamllint`

`main` への push が成功すると、GitHub Actions は x64 / arm64 の matrix で
lint / build / test を実行し、その結果を使って
`ghcr.io/chalharu/copilot-sandbox-container/<image>` に amd64 / arm64 を含む
multi-arch manifest として公開します。公開 tag は `latest` と commit SHA に加え、
同梱ツールの version tag も更新します。

- `control-plane`: `copilot-<COPILOT_CLI_VERSION>`
- `yamllint`: `<YAMLLINT_VERSION>`

これらの version tag は「どのツール version を同梱しているか」を示す利便用です。
厳密な再現性が必要な場合は、引き続き commit SHA tag を使ってください。
なお GitHub Actions は GHCR の古い package version を自動削除し、各イメージにつき
直近 30 version を保持します。
また、`containers/yamllint/` の DHI base image pull には
`DOCKERHUB_USERNAME` と `DOCKERHUB_TOKEN` を使い、GitHub Actions 上で
pull 結果を cache して rate limit を避けます。

## Kubernetes 配備

テンプレートは `deploy/kubernetes/control-plane.example.yaml` にあります。
この例は raw Pod ではなく、Secret / Service / Deployment / PVC をまとめた
単一レプリカ構成です。SSH 公開鍵は Secret から渡し、必要なら同じ Secret で
`COPILOT_GITHUB_TOKEN` も注入できます。SSH host key も同じ PVC 上に永続化される
ため、Pod の再作成で fingerprint が変わりません。

対話的な SSH ログインでは GNU Screen の session picker が起動します。既存の
Copilot セッションが無い場合は picker に `Copilot (/workspace, --yolo)` が追加され、
Enter だけで `/workspace` から `copilot --yolo` を始められます。Copilot 用の
Screen session は detached ではなく SSH TTY に直接 attach した状態で起動するため、
ログイン直後に応答が消えにくくなっています。また、
`control-plane-operations` skill をイメージに同梱しているため、他のリポジトリを
`/workspace` に mount した場合でも同じ運用ガイドを使えます。

同じサンプル Deployment では capability を `CHOWN` / `DAC_OVERRIDE` / `FOWNER` /
`SETGID` / `SETUID` / `SYS_CHROOT` に絞り、`RuntimeDefault` seccomp と
`CONTROL_PLANE_RUN_MODE=k8s-job`、`fsGroup: 1000` を使っているため、SSH で入ったあとも権限を
絞ったまま運用しやすくしています。local Podman / Kind は outer runtime 次第なので、
`scripts/lint.sh` や `scripts/build-test.sh` が Pod 内で詰まる場合は GitHub Actions
側で実行してください。

Control Plane イメージには `vim` も同梱され、ログイン shell では `EDITOR` /
`VISUAL` を未設定時だけ `vim` に補います。Copilot CLI の multiline shortcut が
通らない環境でも、`Ctrl+G` で外部 editor を開く運用をすぐ使えます。

`gh` については SSH / GNU Screen 越しでも pager 待ちで止まって見えにくいよう、
login shell では `GH_PAGER=cat` を既定化しています。

また、SSHD は `LANG` / `LC_*` を受け取り、client が送らない場合でも login shell
では `LANG=C.UTF-8` を補います。イメージ側では `en_US.UTF-8` と `ja_JP.UTF-8`
も生成してあるため、`LC_ALL=en_US.UTF8` のような SSH client 由来の locale でも
warning を出しにくく、日本語や記号を含む UTF-8 テキストを SSH / GNU Screen
越しで表示しやすくしています。

GNU Screen には `/etc/screenrc` で `screen-256color` / UTF-8 / alt screen /
background color erase を既定で設定し、Control Plane イメージには
`tmux-256color` や `xterm-256color` を含む追加 terminfo も入れています。これにより
`tmux` 経由の SSH ログインでも表示崩れを起こしにくくしています。

一方で、Copilot CLI の multiline 入力 (`Shift+Enter`) は upstream では Kitty
protocol 対応 terminal を前提とします。対応 terminal では `/terminal-setup` を
実行してください。`tmux` / GNU Screen 経由では key event が転送されず、
`Shift+Enter` や `Ctrl+Enter` が安定しない場合があります。その場合は paste か
`Ctrl+G` を使ってください。

既定の Control Plane イメージは
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest` です。
`copilot-<COPILOT_CLI_VERSION>` tag も使えますが、再現性を優先する場合は
`latest` ではなく commit SHA tag を使ってください。なお公開イメージは
直近 30 version を保持し、それ以前の package version は自動削除されます。

## Execution Plane について

同梱している Execution Plane は、Control Plane 連携を確認するための参照実装です。
一覧を固定することが目的ではありません。`/workspace` 共有や、対象 workflow に
必要なコマンド群まで含めて契約を満たす upstream イメージがあるなら、それを
直接使って構いません。不足がある場合だけ、薄いラッパーイメージを用意します。

より細かい挙動を確認したい場合だけ、下位の `scripts/test-standalone.sh` /
`scripts/test-kind.sh` を直接使ってください。
