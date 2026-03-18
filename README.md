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

このリポジトリを current-cluster 上の Control Plane コンテナ内で扱う場合は、entrypoint が `~/.config/control-plane/runtime.env` を生成し、rootful Podman remote service、秘密情報の file path、Job 実行先 namespace などを login shell へ引き渡します。

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

current-cluster の rootful-service では、DHI base image の事前 pull と build isolation の調整を自動で行います。

## ステップ 3: build とテストを実行する

```bash
./scripts/build-test.sh
```

必要なら toolchain を固定します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

このスクリプトは、Control Plane イメージと smoke 用 Execution Plane イメージを build し、次の下位テストを順に実行します。

- `scripts/test-standalone.sh`
- `scripts/test-regressions.sh`
- `scripts/test-kind.sh`

## ステップ 4: current-cluster を確認する

Kubernetes 上の current-cluster smoke は次で実行します。

```bash
./scripts/test-k8s-job.sh
```

このスクリプトは、現在の Control Plane Pod が使っている image を既定値として拾い、修正済みの entrypoint / wrapper / skill ファイルを ConfigMap 経由で一時 Job に注入して検証します。今回の回帰ポイントである次の項目も確認します。

- `drop: ALL` 系 profile での interactive SSH login が接続維持後も入力を受け付ける
- bundled skill の `references/` 可読性
- rootful-service 下の `podman build`

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
