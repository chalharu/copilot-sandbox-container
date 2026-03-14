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
それ以外では Podman / Buildah 系へフォールバックします。内部では
`containers/control-plane` と `containers/execution-plane-smoke` を build し、
`scripts/test-standalone.sh` と `scripts/test-kind.sh` を順に呼び出します。

Podman / Buildah 系では Kind 内の image 名と一致させるため、デフォルトの tag に
`localhost/` 接頭辞を使います。

## イメージ方針

- 契約を満たす trusted upstream image がある場合は、それをそのまま使います。
- 使えるのが third-party image だけ、またはこのリポジトリ専用の薄い調整が必要な
  場合は、リポジトリ内で最小イメージを build します。
- そのようなリポジトリ管理イメージは GHCR に公開して再利用します。

現時点の GHCR 公開対象:

- `control-plane`
- `yamllint`

`main` への push が成功すると、GitHub Actions はこれらを
`ghcr.io/chalharu/copilot-sandbox-container/<image>` に公開し、
`latest` と commit SHA の tag を更新します。
また、`containers/yamllint/` の DHI base image pull には
`DOCKERHUB_USERNAME` と `DOCKERHUB_TOKEN` を使い、GitHub Actions 上で
pull 結果を cache して rate limit を避けます。

## Kubernetes 配備

テンプレートは `deploy/kubernetes/control-plane.example.yaml` にあります。

既定の Control Plane イメージは
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest` です。
再現性を優先する場合は `latest` ではなく commit SHA tag を使ってください。

## Execution Plane について

同梱している Execution Plane は、Control Plane 連携を確認するための参照実装です。
一覧を固定することが目的ではありません。`/workspace` 共有や必要コマンドなどの
契約を満たす upstream イメージがあるなら、それを直接使って構いません。

より細かい挙動を確認したい場合だけ、下位の `scripts/test-standalone.sh` /
`scripts/test-kind.sh` を直接使ってください。
