# copilot-sandbox-container

`copilot-sandbox-container` は、Copilot CLI 向けの Control Plane イメージ、session-scoped Execution Pod bootstrap、smoke 用 Execution Plane イメージ、Kubernetes 配備サンプル、検証スクリプトをまとめたリポジトリです。sample manifest の既定値では、Copilot CLI の `bash` tool を session 単位の Kubernetes Execution Pod へ自動委譲し、明示的な `control-plane-run` も Kubernetes Job 経由で実行します。

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
3. Kubernetes 上の current-cluster で `./scripts/test-k8s-job.sh` を使って runtime / SSH / skill surface を確認する

詳細な運用手順や背景説明は、README の下ではなく Diátaxis 配下へ分離しています。困ったらまず上のリンクに移動してください。

## ステップ 1: 前提をそろえる

最低限、次のコマンドが必要です。

- `git`
- `kubectl`
- `ssh`, `ssh-keygen`
- `docker buildx`
- current-cluster を触る場合は、対象 namespace に対する `kubectl` 権限

current-cluster 上の Control Plane コンテナ内で作業する場合は、先に次の
3 本を押さえると迷いにくくなります。

- runtime.env、永続 state、hook / Git policy:
  `docs/reference/control-plane-runtime.md`
- sample manifest の更新手順:
  `docs/how-to-guides/cookbook.md#3-sample-manifest-を-current-cluster-向けに更新する`
- なぜ session-scoped Execution Pod と Kubernetes Job を併用するのか:
  `docs/explanation/knowledge.md`

## ステップ 2: lint を実行する

```bash
./scripts/lint.sh
```

Docker toolchain を明示したいときは次を使います。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/lint.sh
```

`lint.sh` は次をまとめて実行します。

- `renovate.json5` の検証
- Renovate dry-run による依存関係確認
- `hadolint`
- `shellcheck`
- `yamllint`
- `markdownlint`

`lint.sh` は bundled control-plane image を使って `yamllint` を実行し、
そのほかの lint もコンテナ経由でそろえます。詳細な current-cluster 向け注意点は
`docs/how-to-guides/cookbook.md#1-標準の-lint--build--test-を回す` を
参照してください。

## ステップ 3: build とテストを実行する

```bash
./scripts/build-test.sh
```

必要なら Docker toolchain を明示します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
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
  `scripts/test-config-injection.sh`,
  `scripts/test-k8s-sample-storage-layout.sh`,
  `scripts/test-entrypoint-capabilities.sh`
- audit / bundled skill: `scripts/test-audit-logging.sh`,
  `scripts/test-repo-change-delivery-skills.sh`
- Kind integration: `scripts/test-kind-image-loading.sh`, `scripts/test-kind.sh`
  （SSH / current-cluster profile / fast execution pod / Job path）、
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
- bundled toolchain と runtime.env が期待どおり生成される
- current-cluster 上の SSH / session surface が維持される

sample manifest の更新手順は
`docs/how-to-guides/cookbook.md#3-sample-manifest-を-current-cluster-向けに更新する`、
runtime / state / config 注入の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

sample manifest の既定値では `CONTROL_PLANE_FAST_EXECUTION_ENABLED=1` により、
bundled `preToolUse` hook が Copilot CLI の `bash` tool を
session-scoped Execution Pod へ書き換えます。Execution Pod は同じ
`/workspace` PVC を mount し、`sessionEnd` hook と OwnerReference の両方で
cleanup されます。これは explicit に呼ぶ `control-plane-run` とは別経路です。

すでに Control Plane Pod の中から作業している場合は、追加の spot check として次も使えます。

```bash
./scripts/test-current-cluster-regressions.sh
```

## ステップ 5: 基本的な `control-plane-run` を試す

Kubernetes Job 実行:

```bash
control-plane-run \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/control-plane:replace-me-with-commit-sha \
  -- bash -lc 'printf "%s\n" job > /workspace/job.txt'
```

`control-plane-run` は Kubernetes Job 専用です。Copilot CLI 自身の `bash`
tool delegation はこれとは別に、hook が自動で session-scoped Execution Pod
へ転送します。

## 次に進む

- どの文書を見るべきか迷ったら: `docs/README.md`
- 具体的な運用手順を見たい: `docs/how-to-guides/cookbook.md`
- なぜこの構成なのか知りたい: `docs/explanation/knowledge.md`
- current-cluster へ至る経緯を知りたい: `docs/explanation/history.md`
- runtime / hook / 永続化の path を引きたい:
  `docs/reference/control-plane-runtime.md`
- 代表的な失敗ログを引きたい: `docs/reference/debug-log.md`
