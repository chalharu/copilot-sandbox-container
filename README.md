# copilot-sandbox-container

`copilot-sandbox-container` は、Copilot CLI 向けの Control Plane イメージ、用途別 Execution Plane の参照実装、Kubernetes 配備サンプル、検証スクリプトをまとめたリポジトリです。

## 読み始める場所

- 最短でセットアップと検証を通す: `README.md`（このドキュメント）
- どの文書を見るべきか迷ったら: `docs/README.md`
- How-to guides: `docs/how-to-guides/cookbook.md`
- current-cluster の runtime / hook / 永続化の事実関係: `docs/reference/control-plane-runtime.md`
- Explanation: `docs/explanation/knowledge.md`
- History: `docs/explanation/history.md`
- Reference: `docs/reference/debug-log.md`
- Contribution rules: `CONTRIBUTING.md`

## この quickstart で通すこと

この quickstart では、次の 3 つを最短で通します。

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

current-cluster 上の Control Plane コンテナ内で作業する場合は、先に次の
3 本を押さえると迷いにくくなります。

- runtime.env、永続 state、Podman cache、hook / Git policy、Rust の sccache S3 / Garage runtime:
  `docs/reference/control-plane-runtime.md`
- sample manifest の更新手順:
  `docs/how-to-guides/cookbook.md#3-sample-manifest-を-current-cluster-向けに更新する`
- なぜ rootful-service + Kubernetes Job が既定なのか:
  `docs/explanation/knowledge.md#4-なぜ-current-cluster-では-rootful-service-fallback-なのか`

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

current-cluster の rootful-service では、remote Podman socket の優先、
DHI base image の事前 pull、build isolation の調整まで `lint.sh` 側で
吸収します。詳細な current-cluster 向け注意点は
`docs/how-to-guides/cookbook.md#1-標準の-lint--build--test-を回す` を
参照してください。

## ステップ 3: build とテストを実行する

```bash
./scripts/build-test.sh
```

必要なら toolchain を固定します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

`--build-only` や `--skip-image-build --group ...` の focused rerun は
`docs/how-to-guides/cookbook.md#1-標準の-lint--build--test-を回す` を
参照してください。

既定の baseline は、Control Plane イメージと smoke 用 Execution Plane
イメージを build したうえで、次の 4 系統を順に確認します。

- standalone / regressions: `scripts/test-standalone.sh`,
  `scripts/test-regressions.sh`
- config / runtime / permissions:
  `scripts/test-renovate-config-permissions.sh`,
  `scripts/test-config-injection.sh`, `scripts/test-podman-startup.sh`,
  `scripts/test-k8s-sample-storage-layout.sh`,
  `scripts/test-entrypoint-capabilities.sh`
- audit / bundled skill: `scripts/test-audit-logging.sh`,
  `scripts/test-audit-analysis.sh`, `scripts/test-repo-change-delivery-skills.sh`
- Kind integration: `scripts/test-kind-image-loading.sh`, `scripts/test-kind.sh`,
  `scripts/test-job-transfer.sh`

focused rerun では `--build-only` と
`--skip-image-build --group <smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer>`
を組み合わせ、image build を 1 回に固定してから必要な test group だけ
回せます。

## ステップ 4: current-cluster を確認する

Kubernetes 上の current-cluster smoke は次で実行します。

```bash
./scripts/test-k8s-job.sh
```

このスクリプトでは、少なくとも次を確認します。

- `drop: ALL` 系 profile での interactive SSH login が接続維持後も入力を受け付ける
- bundled skill の `references/` 可読性
- rootful-service の Podman graphroot / runtime dir が disposable path を使う
- rootful-service 下の `podman build`

sample manifest の更新手順は
`docs/how-to-guides/cookbook.md#3-sample-manifest-を-current-cluster-向けに更新する`、
runtime / state / config 注入の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

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

current-cluster では local Podman ではなく Kubernetes Job path が既定です。
`--execution-hint short` は、対話性や速度を優先したいときの明示 opt-in と
考えてください。

## 次に進む

- どの文書を見るべきか迷ったら: `docs/README.md`
- 具体的な運用手順を見たい: `docs/how-to-guides/cookbook.md`
- なぜこの構成なのか知りたい: `docs/explanation/knowledge.md`
- current-cluster へ至る経緯を知りたい: `docs/explanation/history.md`
- runtime / hook / 永続化の path を引きたい:
  `docs/reference/control-plane-runtime.md`
- 代表的な失敗ログを引きたい: `docs/reference/debug-log.md`
