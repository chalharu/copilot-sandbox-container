# copilot-sandbox-container

Control Plane / Execution Plane の要件は `docs/requirements.md` にあります。

このリポジトリには、要件に基づく以下の実装と参照用サンプルを含みます。

- `containers/control-plane/`: Control Plane イメージ
- `containers/hadolint/`: Dockerfile lint 用 `hadolint` コンテナ
- `containers/execution-plane-rust/`: Rust 向け Execution Plane の参照実装
- `containers/execution-plane-python/`: Python 向け Execution Plane の参照実装
- `containers/execution-plane-go/`: Go 向け Execution Plane の参照実装
- `containers/execution-plane-node/`: Node.js 向け Execution Plane の参照実装
- `containers/execution-plane-smoke/`: テスト用の最小 Execution Plane
- `deploy/kubernetes/control-plane.example.yaml`: Kubernetes 向けの配備例
- `docs/kubernetes-deployment.md`: Kubernetes 配備時の調整ポイント
- `scripts/test-standalone.sh`: 単独起動モードの smoke test
- `scripts/test-kind.sh`: Docker / Podman provider の Kind を使った
 Kubernetes モードの統合テスト
- `.github/workflows/control-plane-ci.yml`: `hadolint` / buildah build /
 smoke / Kind integration を行う CI

ローカルでの lint 例 (Docker / BuildKit):

```bash
docker buildx build --load -t hadolint:test containers/hadolint
docker run --rm -v "$PWD:/workspace:ro" hadolint:test \
 /workspace/containers/control-plane/Dockerfile \
 /workspace/containers/execution-plane-smoke/Dockerfile \
 /workspace/containers/execution-plane-rust/Dockerfile \
 /workspace/containers/execution-plane-python/Dockerfile \
 /workspace/containers/execution-plane-go/Dockerfile \
 /workspace/containers/execution-plane-node/Dockerfile \
 /workspace/containers/hadolint/Dockerfile
shellcheck containers/control-plane/bin/* \
 containers/execution-plane-smoke/execution-plane-smoke \
 scripts/test-standalone.sh scripts/test-kind.sh
```

ローカルでの lint 例 (Podman / Buildah):

```bash
buildah bud -t hadolint:test containers/hadolint
podman run --rm -v "$PWD:/workspace:ro" hadolint:test \
 /workspace/containers/control-plane/Dockerfile \
 /workspace/containers/execution-plane-smoke/Dockerfile \
 /workspace/containers/execution-plane-rust/Dockerfile \
 /workspace/containers/execution-plane-python/Dockerfile \
 /workspace/containers/execution-plane-go/Dockerfile \
 /workspace/containers/execution-plane-node/Dockerfile \
 /workspace/containers/hadolint/Dockerfile
shellcheck containers/control-plane/bin/* \
 containers/execution-plane-smoke/execution-plane-smoke \
 scripts/test-standalone.sh scripts/test-kind.sh
```

ローカルでの build / test 例 (Docker / BuildKit):

```bash
docker buildx build --load -t control-plane:test containers/control-plane
docker buildx build --load -t execution-plane-smoke:test containers/execution-plane-smoke
CONTROL_PLANE_CONTAINER_BIN=docker \
  ./scripts/test-standalone.sh control-plane:test execution-plane-smoke:test
KIND_EXPERIMENTAL_PROVIDER=docker CONTROL_PLANE_CONTAINER_BIN=docker \
  ./scripts/test-kind.sh control-plane:test execution-plane-smoke:test control-plane-ci
```

ローカルでの build / test 例 (Podman / Buildah):

```bash
buildah bud -t control-plane:test containers/control-plane
buildah bud -t execution-plane-smoke:test containers/execution-plane-smoke
./scripts/test-standalone.sh control-plane:test execution-plane-smoke:test
KIND_EXPERIMENTAL_PROVIDER=podman CONTROL_PLANE_CONTAINER_BIN=podman ./scripts/test-kind.sh \
  control-plane:test execution-plane-smoke:test control-plane-ci
```

`scripts/test-kind.sh` は `${CONTROL_PLANE_CONTAINER_BIN:-$KIND_EXPERIMENTAL_PROVIDER}`
の `save` サブコマンドでローカルイメージをアーカイブし、
`kind load image-archive` でクラスタへ投入します。Docker / BuildKit と
Podman / Buildah のどちらの流れでも、対象イメージがローカルの image
store に見えていれば同じスクリプトを使えます。Buildah で build した
イメージを扱う場合は `CONTROL_PLANE_CONTAINER_BIN=podman` を指定します。

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
から同じ `scripts/test-standalone.sh` / `scripts/test-kind.sh` を呼び出せます。
この 2 つのスクリプトは `CONTROL_PLANE_CONTAINER_BIN` を共有し、ローカルの
コンテナ実行系を切り替えられるようにしてあります。
