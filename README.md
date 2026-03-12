# copilot-sandbox-container

Control Plane / Execution Plane の要件は `docs/requirements.md` にあります。

このリポジトリには、要件に基づく以下の実装を含みます。

- `containers/control-plane/`: Control Plane イメージ
- `containers/execution-plane-smoke/`: テスト用の最小 Execution Plane
- `scripts/test-standalone.sh`: 単独起動モードの smoke test
- `scripts/test-kind.sh`: Kind を使った Kubernetes モードの統合テスト
- `.github/workflows/control-plane-ci.yml`: `hadolint` / build / smoke / Kind integration を行う CI

ローカルでの lint 例:

```bash
hadolint containers/control-plane/Dockerfile containers/execution-plane-smoke/Dockerfile
shellcheck containers/control-plane/bin/* containers/execution-plane-smoke/execution-plane-smoke scripts/test-standalone.sh scripts/test-kind.sh
```
