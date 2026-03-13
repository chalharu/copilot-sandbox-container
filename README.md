# copilot-sandbox-container

Control Plane / Execution Plane の要件は `docs/requirements.md` にあります。

このリポジトリには、要件に基づく以下の実装と参照用サンプルを含みます。

- `containers/control-plane/`: Control Plane イメージ
- `containers/execution-plane-rust/`: Rust 向け Execution Plane の参照実装
- `containers/execution-plane-python/`: Python 向け Execution Plane の参照実装
- `containers/execution-plane-go/`: Go 向け Execution Plane の参照実装
- `containers/execution-plane-node/`: Node.js 向け Execution Plane の参照実装
- `containers/execution-plane-smoke/`: テスト用の最小 Execution Plane
- `deploy/kubernetes/control-plane.example.yaml`: Kubernetes 向けの配備例
- `docs/kubernetes-deployment.md`: Kubernetes 配備時の調整ポイント
- `scripts/lint.sh`: `hadolint` と `shellcheck` をまとめて実行する lint 用スクリプト
- `scripts/build-test.sh`: ローカルの Docker または Podman / Buildah を検出して
  build / smoke / Kind integration をまとめて実行するスクリプト
- `scripts/test-standalone.sh`: 単独起動モードの smoke test
- `scripts/test-kind.sh`: Docker / Podman provider の Kind を使った
 Kubernetes モードの統合テスト
- `.github/workflows/control-plane-ci.yml`: `scripts/lint.sh` と
 `scripts/build-test.sh` を使って検証する CI

推奨するローカル lint 実行:

```bash
./scripts/lint.sh
```

`scripts/lint.sh` は `docker` があればそれを使い、なければ `podman` を使って
公式の `hadolint/hadolint:latest-debian` イメージを直接実行します。
Podman を明示したい場合は次のように指定できます。

```bash
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh
```

推奨するローカル build / test 実行:

```bash
./scripts/build-test.sh
```

`scripts/build-test.sh` は `docker` があれば Docker / BuildKit の流れを使い、
Docker が無い場合は `buildah` と `podman` の組み合わせへフォールバックします。
使用する系統を固定したい場合は `CONTROL_PLANE_TOOLCHAIN=docker` または
`CONTROL_PLANE_TOOLCHAIN=podman` を指定します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

`scripts/build-test.sh` は `containers/control-plane` と
`containers/execution-plane-smoke` を build したうえで、
`scripts/test-standalone.sh` と `scripts/test-kind.sh` を順に呼び出します。
`scripts/test-kind.sh` は `${CONTROL_PLANE_CONTAINER_BIN:-$KIND_EXPERIMENTAL_PROVIDER}`
の `save` サブコマンドでローカルイメージをアーカイブし、
`kind load image-archive` でクラスタへ投入します。

CI や WSL 系の環境で rootless Podman 上の Kind 起動が
systemd / cgroup 制約により失敗する場合、`scripts/test-kind.sh` は
passwordless sudo が利用可能であれば rootful な Kind 実行へ自動で
フォールバックします。常に sudo フォールバックを使いたい場合は
`CONTROL_PLANE_KIND_SUDO_MODE=always`、無効化したい場合は
`CONTROL_PLANE_KIND_SUDO_MODE=never` を指定できます。

Execution Plane サンプルはすべて `/workspace` を作業ディレクトリとして
使う前提で、Control Plane から Podman 実行または Kubernetes Job 実行へ
切り替えて利用できます。ここで同梱している各 Execution Plane は
Control Plane 連携を確認するための最小サンプルであり、網羅的な一覧では
ありません。upstream の公式イメージが `/workspace` 共有や必要コマンドの
条件をそのまま満たす場合は、それらを直接使ってかまいません。不足がある
場合にだけ、このリポジトリのような薄いラッパーイメージを追加する前提です。

この方針により、このリポジトリ自身の開発でも Docker / Podman 系の実行環境
から同じ `scripts/lint.sh` / `scripts/build-test.sh` を呼び出せます。より細かい
制御が必要な場合だけ、下位の `scripts/test-standalone.sh` /
`scripts/test-kind.sh` を直接使います。
