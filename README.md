# copilot-sandbox-container

Control Plane / Execution Plane の要件は `docs/requirements.md` にあります。

このリポジトリには、要件に基づく以下の実装を含みます。

- `containers/control-plane/`: Control Plane イメージ
- `containers/hadolint/`: Dockerfile lint 用 `hadolint` コンテナ
- `containers/execution-plane-rust/`: Rust 向け Execution Plane サンプル
- `containers/execution-plane-python/`: Python 向け Execution Plane サンプル
- `containers/execution-plane-go/`: Go 向け Execution Plane サンプル
- `containers/execution-plane-node/`: Node.js 向け Execution Plane サンプル
- `containers/execution-plane-smoke/`: テスト用の最小 Execution Plane
- `deploy/kubernetes/control-plane.example.yaml`: Kubernetes 向けの配備例
- `docs/kubernetes-deployment.md`: Kubernetes 配備時の調整ポイント
- `scripts/test-standalone.sh`: 単独起動モードの smoke test
- `scripts/test-kind.sh`: Podman provider の Kind を使った Kubernetes
 モードの統合テスト
- `.github/workflows/control-plane-ci.yml`: `hadolint` / buildah build /
 smoke / Kind integration を行う CI

ローカルでの lint 例:

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

ローカルでの build / test 例:

```bash
buildah bud -t control-plane:test containers/control-plane
buildah bud -t execution-plane-smoke:test containers/execution-plane-smoke
./scripts/test-standalone.sh control-plane:test execution-plane-smoke:test
KIND_EXPERIMENTAL_PROVIDER=podman ./scripts/test-kind.sh \
 control-plane:test execution-plane-smoke:test control-plane-ci
```

`scripts/test-kind.sh` は `skopeo` でローカルのコンテナストレージから
イメージアーカイブを作成し、`kind load image-archive` でクラスタへ投入します。
Docker デーモンは不要です。

CI や WSL 系の環境で rootless Podman 上の Kind 起動が
systemd / cgroup 制約により失敗する場合、`scripts/test-kind.sh` は
passwordless sudo が利用可能であれば rootful な Kind 実行へ自動で
フォールバックします。常に sudo フォールバックを使いたい場合は
`CONTROL_PLANE_KIND_SUDO_MODE=always`、無効化したい場合は
`CONTROL_PLANE_KIND_SUDO_MODE=never` を指定できます。

Execution Plane サンプルはすべて `/workspace` を作業ディレクトリとして
使う前提で、Control Plane から Podman 実行または Kubernetes Job 実行へ
切り替えて利用できます。
