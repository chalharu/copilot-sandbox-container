# copilot-sandbox-container

`copilot-sandbox-container` は、Copilot CLI 向けの Control Plane イメージ、用途別 Execution Plane の参照実装、Kubernetes 配備サンプル、検証スクリプトをまとめたリポジトリです。

## 先に読む場所

- Tutorial: `README.md`（このドキュメント）
- How-to guides: `docs/how-to-guides/cookbook.md`
- Explanation: `docs/explanation/knowledge.md`
- History: `docs/explanation/history.md`
- Reference: `docs/reference/debug-log.md`
- Contribution rules: `CONTRIBUTING.md`

## この tutorial で得るもの

この tutorial では、次の 3 つを最短で通します。

1. `./scripts/lint.sh` で lint を通す
2. `./scripts/build-test.sh` で build / standalone smoke / Kind integration を回す
3. Kubernetes 上の current-cluster で `./scripts/test-k8s-job.sh` を使って rootful-service smoke を確認する

詳細な運用手順や背景説明は、README の下ではなく Diátaxis 配下へ分離しています。困ったらまず上のリンクに移動してください。

## ステップ 1: 前提をそろえる

最低限、次のコマンドが必要です。

- `git`
- `kubectl`
- `ssh`, `ssh-keygen`
- `docker buildx` または `podman`
- current-cluster を触る場合は、対象 namespace に対する `kubectl` 権限

このリポジトリを current-cluster 上の Control Plane コンテナ内で扱う場合は、entrypoint が `~/.config/control-plane/runtime.env` を生成し、rootful Podman remote service、`TZ` で指定した IANA timezone、Copilot CPU cap、監査ログ SQLite DB path / record cap、秘密情報の file path、Job 実行先 namespace などを login shell へ引き渡します。あわせて、`COPILOT_CONFIG_JSON_FILE` で渡した ConfigMap JSON を RWX の copilot session PVC 上にある既存 `~/.copilot/config.json` へ deep-merge し、同じ PVC で `~/.copilot/command-history-state.json`、`~/.copilot/session-state`、`~/.copilot/session-state/audit/audit-log.db`、`~/.copilot/session-state/audit/audit-analysis.db`、`~/.config/gh`、`~/.ssh`、SSH host key を持ち越します。`controlPlane.auditAnalysis` を ConfigMap overlay に入れると、bundled `audit-log-analysis` skill と lifecycle analysis hooks (`agentStop` / `subagentStop` / `sessionEnd` / `errorOccurred`) が参照する target repository URL や閾値も永続 state と同じ流れで更新できます。`~/.copilot/tmp` と rootful Podman cache は永続化せず、`GH_HOSTS_YML_FILE` または `GH_GITHUB_TOKEN_FILE` から `~/.config/gh/hosts.yml` を反映できます。

Control Plane entrypoint は bundled Copilot hook に加えて bundled Git hook も `~/.copilot/hooks/git` へ同期し、`/home/copilot/.gitconfig` の `core.hooksPath` をそこへ向けます。これにより `main` / `master` への commit / push を止めつつ、pre-commit では bundled `postToolUse` linter を走らせ、必要なら repo ごとの `.github/git-hooks/pre-commit` / `.github/git-hooks/pre-push` も実行できます。

## ステップ 2: lint を実行する

```bash
./scripts/lint.sh
```

Podman 系を明示したいときは次を使います。

```bash
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh
```

`lint.sh` は次をまとめて実行します。

- `renovate.json5` の検証
- Renovate dry-run による依存関係確認
- `hadolint`
- `shellcheck`
- `yamllint`
- `markdownlint`

current-cluster の rootful-service では、remote Podman socket を優先しつつ、DHI base image の事前 pull と build isolation の調整を自動で行います。

## ステップ 3: build とテストを実行する

```bash
./scripts/build-test.sh
```

必要なら toolchain を固定します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --build-only
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --skip-image-build --group smoke
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --skip-image-build --group kind-session
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --skip-image-build --group kind-jobs
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --skip-image-build --group kind-jobs-core
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh --skip-image-build --group kind-jobs-transfer
```

このスクリプトは、Control Plane イメージと smoke 用 Execution Plane イメージを build し、既定では次の下位テストを順に実行します。

- `scripts/test-standalone.sh`
- `scripts/test-regressions.sh`
- `scripts/test-renovate-config-permissions.sh`
- `scripts/test-config-injection.sh`
- `scripts/test-podman-startup.sh`
- `scripts/test-k8s-sample-storage-layout.sh`
- `scripts/test-kind-image-loading.sh`
- `scripts/test-audit-logging.sh`
- `scripts/test-audit-analysis.sh`
- `scripts/test-repo-change-delivery-skills.sh`
- `scripts/test-entrypoint-capabilities.sh`
- `scripts/test-kind.sh`

Kind integration では、`scripts/test-job-transfer.sh` も通して `--mount-file` の大きいファイル転送、Job 完了時の write-back、外部更新との競合保護を確認します。

CI や focused rerun 向けには、`--build-only` と `--skip-image-build --group <smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer>` を使って、image build を 1 回にしてから各 test group を分けて実行できます。`kind` と `kind-jobs` は従来どおり Kind の全シナリオと Job 系シナリオ全体を一括実行し、CI では `kind-session`、`kind-jobs-core`、`kind-jobs-transfer` に分けて wall-clock を短縮します。Hosted CI の Kind jobs は、download 済みの multi-image archive をそのまま Kind に import し、`podman load -> podman save` の往復を避けます。さらに split 済みの `kind-session` / `kind-jobs-core` では重複する rootful Podman smoke を省き、共通 runtime smoke は full Kind path と `kind-jobs-transfer` で代表実行します。

## ステップ 4: current-cluster を確認する

Kubernetes 上の current-cluster smoke は次で実行します。

```bash
./scripts/test-k8s-job.sh
```

このスクリプトは、現在の Control Plane Pod が使っている image を既定値として拾い、修正済みの entrypoint / wrapper / skill ファイルを ConfigMap 経由で一時 Job に注入して検証します。今回の回帰ポイントである次の項目も確認します。

- `drop: ALL` 系 profile での interactive SSH login が接続維持後も入力を受け付ける
- bundled skill の `references/` 可読性
- rootful-service の Podman graphroot が `/var/lib/control-plane/rootful-podman/rootful-overlay/storage` の disposable cache volume を使い、runtime dir は `/var/tmp/control-plane/rootful-overlay` の disk-backed temp path へ逃がされる
- rootful-service 下の `podman build`

sample manifest では、`control-plane-auth` Secret に `ssh-public-key` と必要な Secret 値 (`gh-github-token` または `gh-hosts.yml`, `copilot-github-token`, DockerHub 認証情報) を入れ、`control-plane-config` ConfigMap に `copilot-config.json` overlay を置きます。さらに `control-plane-env` ConfigMap に file path / namespace / Job 既定値のような非機密 env をまとめ、Deployment は `envFrom` でそれらを読み込みます。永続化は RWX の copilot session PVC と RWO の `/workspace` PVC を基本にし、前者へ `~/.copilot/config.json`、`~/.copilot/command-history-state.json`、`~/.copilot/session-state`、`~/.copilot/session-state/audit/audit-log.db`、`~/.copilot/session-state/audit/audit-analysis.db`、`~/.config/gh`、`~/.ssh`、SSH host key をまとめます。監査ログ DB は `control-plane-env` ConfigMap の `CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）を超えた tool hook 実行時に、古いレコードから削除しておおむね上限の 3/4 件まで戻します。bundled `audit-log-analysis` skill は同じ PVC 上の analysis DB を読み、`controlPlane.auditAnalysis.targetRepository.url` などの非機密設定から target repository を決めます。rootful Podman cache と `~/.copilot/tmp` は emptyDir の ephemeral storage へ逃がし、Job の `--mount-file` は ConfigMap ではなく SSH/SFTP + `rclone` で渡して、変更されたファイルは競合を検知しながら write-back します。

すでに Control Plane Pod の中から作業している場合は、追加の spot check として次も使えます。

```bash
./scripts/test-current-cluster-regressions.sh
```

## ステップ 5: 基本的な `control-plane-run` を試す

短いローカル実行:

```bash
control-plane-run --mode auto --execution-hint short \
  --workspace /workspace \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/short.txt short
```

長い Job 実行:

```bash
control-plane-run --mode auto --execution-hint long \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long
```

## 次に進む

- 具体的な運用手順を見たい: `docs/how-to-guides/cookbook.md`
- なぜこの構成なのか知りたい: `docs/explanation/knowledge.md`
- current-cluster へ至る経緯を知りたい: `docs/explanation/history.md`
- 代表的な失敗ログを引きたい: `docs/reference/debug-log.md`
