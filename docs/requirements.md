# Copilot CLI Sandbox Container 要件

## 1. 目的

本構成の目的は、Copilot CLI を中心とする Control Plane を、単独起動環境と Kubernetes 環境の両方で共通運用できるようにすることです。

あわせて、短時間で対話性が重要な処理は Podman で高速に実行し、長時間かかる処理は Kubernetes Job に振り分けることで、開発体験と実行信頼性を両立します。

さらに、Control Plane の状態を永続化し、SSH と GNU Screen により安定した接続とセッション継続性を確保します。

## 2. 用語

- **Control Plane**: Copilot CLI を実行し、Podman と `kubectl` を使って実行環境を制御する統合オーケストレーター
- **Execution Plane**: 実際のビルド・テスト・実行を担当する実行環境。Podman コンテナまたは Kubernetes Job として提供される
- **単独起動モード**: Control Plane をローカル環境、Docker、または Podman 上で動かすモード
- **Kubernetes モード**: 同じ Control Plane を Kubernetes 上の Pod として動かすモード
- **Podman 実行**: 高速で短時間の処理を `rootless Podman` 経由で実行する方式
- **K8s Job 実行**: 長時間の処理を Kubernetes Job として実行する方式

## 3. 全体方針

- Control Plane は、単独起動モードと Kubernetes モードの 2 つをサポートする
- 同じ Control Plane をローカル環境と Kubernetes の両方で利用できるようにする
- Control Plane は、Podman による高速ローカル実行、`kubectl` による K8s Job 実行、SSH 接続、セッション維持、状態永続化を担う統合オーケストレーターとして振る舞う
- 短時間処理は Podman 実行、長時間処理は K8s Job 実行に振り分ける
- ユーザー接続は `kubectl exec` に依存せず、SSH と GNU Screen により安定した対話環境を提供する
- `~/.copilot`、`~/.config/gh`、必要に応じて `~/.ssh`、および `/workspace` を永続化する
- 言語別ツールチェーンは Control Plane に同梱せず、Execution Plane に分離する
- Execution Plane は用途ごとの契約として扱い、リポジトリ内に網羅的な
  イメージ群を常設すること自体を目的にしない

## 4. 必須要件

### 4.1 Control Plane 基本要件

Control Plane は、以下を含む必要があります。

- Copilot CLI を実行できること
- `Node.js (LTS)` と `npm`
- `@github/copilot`
- `gh` と `git`
- `docker` CLI 互換を備えた `rootless Podman`
- `kubectl`
- SSH サーバー (`sshd`)
- `GNU Screen` または `tmux`

一方で、Control Plane は原則として以下を含まないものとします。

- Rust toolchain
- Python
- Go
- Java
- `build-essential`
- その他の言語別ツールチェーン一式

つまり Control Plane は、オーケストレーションに必要な機能のみを持ち、言語別の実行依存関係は Execution Plane 側に分離する前提です。

### 4.2 Control Plane 運用モード要件

Control Plane は、以下の 2 モードで動作できる必要があります。

- **単独起動モード**: ローカル環境、Docker、または Podman 上で動作する
- **Kubernetes モード**: Kubernetes 上の Control Plane Pod として動作する

また、両モードではできる限り同一の Control Plane イメージと運用フローを使えるようにし、環境差分はデプロイ方法と永続化設定に閉じ込めるものとします。

### 4.3 接続とセッション維持要件

- Kubernetes モードでは、対話接続の主経路として SSH を提供すること
- `kubectl exec` は保守や初期調査の補助手段にとどめ、主たる対話手段にしないこと
- 接続断が発生しても、`GNU Screen` または `tmux` によりセッションを再開できること
- Copilot CLI の対話セッションが、通信断や再接続で失われにくいこと

### 4.4 状態永続化要件

Control Plane では、以下のディレクトリを永続化する必要があります。

- `~/.copilot`
- `~/.config/gh`
- `~/.ssh` (Git 操作や外部接続に SSH 鍵が必要な場合)
- `/workspace`

ここで `/workspace` は、プロジェクト本体を配置する永続化可能な作業ディレクトリとします。

単独起動モードではホスト側ボリュームまたは bind mount、Kubernetes モードでは Persistent Volume などを用いて、これらの状態を再起動後も保持できるようにする必要があります。

### 4.5 ハイブリッド実行モデル要件

Control Plane は、処理内容に応じて実行方式を切り替える必要があります。

#### Podman 実行を選ぶ処理

- Linter (`clippy`, `eslint`, `flake8` など)
- 小規模ビルド
- 静的解析
- 数秒以内の応答が必要な処理

#### K8s Job 実行を選ぶ処理

- フルビルド (`cargo build --release` など)
- 大規模テスト
- CI 的な処理
- 数十秒から数分かかる処理

実行方式の切り替えは、少なくとも想定実行時間、対話性の要求、再実行性やログ収集の必要性に基づいて判断できる必要があります。

また、Copilot CLI から見た操作感は、どちらの実行方式でも極力統一される必要があります。

### 4.6 K8s Job 連携要件

Control Plane には、Kubernetes Job を扱うためのスクリプトまたは同等の仕組みを実装する必要があります。

必要な機能は以下のとおりです。

- Job の起動
- Job の完了、失敗、タイムアウトの待機と判定
- 実行 Pod 名の取得
- ログの取得
- 実行結果を Copilot CLI に返すこと

また、Control Plane と Job は同一 namespace に固定しないものとし、少なくとも次を扱える必要があります。

- Control Plane namespace と Job namespace を分離できること
- Control Plane が Job namespace の Job / Pod / Pod logs を操作できること
- 小さい補助ファイルは ConfigMap などで Job へ受け渡せること
- `/workspace` 全体が必要な場合は、Job namespace 側の shared storage か同等の受け渡し手段を選べること

### 4.7 Execution Plane 要件

Execution Plane は、以下を満たす必要があります。

- 実際のビルド・テスト・実行を担当すること
- 必要に応じて言語別または用途別に独立した実行環境として提供されること
- 単独起動モードでは Podman コンテナ、Kubernetes モードでは Job
  実行環境として利用できること
- 必要なツールチェーンとネイティブ依存関係を各実行環境内に閉じ込めること
- 対象プロジェクトの内容にアクセスできること
- 言語ごとに独立して追加・更新できること

ただし、すべての Execution Plane をこのリポジトリで個別に持つ必要は
ありません。公式イメージが `/workspace` の共有、対象 workflow に必要な
コマンド、実行ユーザーなどの契約をそのまま満たす場合は upstream イメージを
直接使い、不足がある場合だけ薄いラッパーイメージを用意する前提とします。
trusted upstream image が存在しない場合は、このリポジトリで最小イメージを
build して GHCR へ公開し、再利用できるようにします。

このリポジトリに同梱する Execution Plane は、Control Plane との結合点を
確認するための参照実装です。対象言語や用途の一覧を固定することは目的では
なく、このリポジトリ自身をコンテナ内で開発・検証するための
コンテナツール用実行環境を追加または流用できることも要件に含みます。

`/workspace` の扱いは環境に応じて次のようにします。

- 単独起動モードでは、Control Plane と実行コンテナが同じ `/workspace` を共有する
- Kubernetes モードでは、Control Plane Pod と K8s Job が同じ
   Persistent Volume、namespace ごとに用意した同等の共有ストレージ、または
   ファイル受け渡し手段を通じて必要な `/workspace` 内容を参照する

Kubernetes モードで Job namespace を分ける場合、Control Plane namespace の PVC を
そのまま Job Pod に mount できるとは限りません。大きい workspace は shared storage を、
小さい入力は ConfigMap 等の埋め込みを使い分ける前提とします。

### 4.8 言語別実行環境の構成例

#### Rust 実行環境

- 含めるもの: `rustup`, `cargo`, `sccache`, `build-essential`, `libssl-dev`, `pkg-config`
- 利用する作業ディレクトリ: `/workspace`

#### Python 実行環境

- 含めるもの: `python3`, `pip`, `venv`
- 利用する作業ディレクトリ: `/workspace`

#### Go 実行環境

- 含めるもの: `go`, `dlv`
- 利用する作業ディレクトリ: `/workspace`

#### Node.js 実行環境

- 含めるもの: `node`, `npm` または `pnpm`
- 利用する作業ディレクトリ: `/workspace`

#### コンテナツール実行環境

- 想定用途: このリポジトリ自身の Dockerfile lint、image build、smoke test、
  Kind integration test
- 含める候補: `docker` 互換 CLI、`podman` または `buildah`、`kind`、
  `kubectl`、`ssh`、`ssh-keygen`
- 提供方法: 専用の Execution Plane を追加してもよいし、
  `quay.io/buildah/stable` などの upstream イメージが上記 workflow に必要な
  コマンド一式を満たすなら、そのまま使ってもよい。不足がある場合だけ薄い
  ラッパーイメージで補う

上記はあくまで構成例であり、各実行環境は用途に応じて自由に追加・調整できる
ものとします。公式イメージをそのまま使える場合はそれを優先し、この
リポジトリでは不足分だけを薄く補う構成を基本とします。

### 4.9 安全性と運用要件

- 既定で `privileged` を前提にしないこと（sample deployment は Pod user namespace
  と `RuntimeDefault` seccomp を基本にし、`securityContext.privileged` は本当に
  必要なときだけ明示的な opt-in として許容する）
- `securityContext.privileged: true` でも nested user namespace が保証されるとは
  限らないこと。outer runtime が `newuidmap` / `newgidmap` や user namespace を
  禁止している場合、rootless Podman は失敗し得る
- Docker-in-Docker のような root 権限依存の構成を避けること
- 言語間の依存関係衝突を防げること
- Control Plane と Execution Plane を独立して更新できること

## 5. 非要件

以下は本構成で目指さないものです。

- Control Plane 単体で全言語のビルドを完結させること
- すべての言語ツールチェーンを 1 つのコンテナに同梱すること
- `kubectl exec` のみを前提に安定した対話環境を実現すること
- すべての処理を Podman のみ、または K8s Job のみで統一すること
- Copilot CLI の状態をエフェメラルなコンテナ内だけに保持すること

## 6. 想定動作フロー

### 6.1 短時間処理を Podman で実行する場合

1. ユーザーは、単独起動モードまたは Kubernetes モードの Control Plane に入る
2. 必要に応じて SSH 接続し、`GNU Screen` または `tmux` 上で作業する
3. `~/.copilot`、`~/.config/gh`、`/workspace` などの永続化領域が利用可能である
4. Copilot CLI が対象処理を短時間処理と判断する
5. Control Plane が Podman を使って対応する言語別実行コンテナを起動する
6. 実行コンテナが `/workspace` を参照してビルド・テスト・解析を行う
7. Copilot CLI が結果を受け取り、次の操作や提案につなげる

### 6.2 長時間処理を K8s Job で実行する場合

1. ユーザーは Kubernetes 上の Control Plane Pod に SSH 接続する
2. `GNU Screen` または `tmux` 上で Copilot CLI セッションを維持する
3. Copilot CLI が対象処理を長時間処理と判断する
4. Control Plane が `kubectl` を使って K8s Job を起動する
5. 必要なら ConfigMap や shared storage を通じて Job へ入力ファイルを渡す
6. Control Plane 内の Job 制御スクリプトが完了待機を行う
7. スクリプトが実行 Pod 名とログを取得する
8. Copilot CLI が実行結果を受け取り、対話を継続する

## 7. 構成イメージ

```text
単独起動モード (local / Docker / Podman)
Host
├─ 永続化ディレクトリ
│  ├─ ~/.copilot
│  ├─ ~/.config/gh
│  ├─ ~/.ssh (必要に応じて)
│  └─ /workspace
└─ Control Plane
   ├─ Copilot CLI / gh / git
   ├─ rootless Podman (docker CLI 互換)
   ├─ kubectl
   ├─ sshd
   ├─ GNU Screen
   └─ Podman が言語別実行コンテナを起動
```

```text
Kubernetes モード
Cluster
├─ Persistent Volume / Persistent Volume Claim
│  ├─ ~/.copilot
│  ├─ ~/.config/gh
│  ├─ ~/.ssh (必要に応じて)
│  └─ /workspace
├─ Control Plane Pod
│  ├─ Copilot CLI / gh / git
│  ├─ rootless Podman (docker CLI 互換)
│  ├─ kubectl
│  ├─ sshd
│  ├─ GNU Screen
│  └─ K8s Job 制御スクリプト
└─ K8s Job 群
   └─ 同じ永続ストレージ上の /workspace を参照して実行
```

## 8. 期待する効果

- ローカル環境と Kubernetes 環境で同じ Control Plane を使い回せる
- SSH と `GNU Screen` により、接続断に強い対話環境を提供できる
- Copilot CLI の会話履歴と GitHub CLI の認証状態を保持できる
- 短時間処理は高速に、長時間処理は堅牢に実行できる
- 言語別実行環境を個別に追加・更新できる
- `rootless Podman` により、より安全に運用できる
