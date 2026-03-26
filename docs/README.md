# Documentation map

このページは、どの文書から読むべきかを素早く判断するための入口です。
最初の 1 本だけを選びたい場合は、下の「よくある目的」から入ってください。

## よくある目的

- 最短で lint / build / test を通したい: `README.md`
- current-cluster の smoke と manifest 更新を進めたい: `docs/how-to-guides/cookbook.md`
- runtime.env、永続 state、Podman cache、hook / Git policy、sccache S3 / Garage の path を引きたい: `docs/reference/control-plane-runtime.md`
- なぜ rootful-service fallback や Kubernetes Job が既定なのか知りたい: `docs/explanation/knowledge.md`
- 現行構成へ至る経緯を追いたい: `docs/explanation/history.md`
- 代表ログから障害点を引きたい: `docs/reference/debug-log.md`
- コントリビュート規約を確認したい: `CONTRIBUTING.md`

## Diátaxis 別の入口

### Tutorial

- `README.md`: このリポジトリで最初に通す lint / build /
  current-cluster smoke の最短導線

### How-to guides

- `docs/how-to-guides/cookbook.md`: current-cluster 運用、sample manifest
  更新、`control-plane-run` の使い分け、SSH login 確認

### Explanation

- `docs/explanation/knowledge.md`: Control Plane / Execution Plane 分離、
  SSH + Screen、rootful-service fallback、ConfigMap / Secret 設計
- `docs/explanation/history.md`: current-cluster 対応や bundled skill 同期、
  ドキュメント再編に至る判断の履歴

### Reference

- `docs/reference/control-plane-runtime.md`: runtime.env、永続 / 一時 state、
  ConfigMap / Secret 注入、hook / Git policy、bundled skill 同期の事実関係
- `docs/reference/debug-log.md`: current-cluster と Control Plane 周辺で重要に
  なる代表ログ断片と意味

## 読み進め方のおすすめ

1. 初回は `README.md`
2. 具体的な操作で詰まったら `docs/how-to-guides/cookbook.md`
3. 設計背景が必要になったら `docs/explanation/knowledge.md`
4. path やログを正確に引きたいときは `docs/reference/*.md`
