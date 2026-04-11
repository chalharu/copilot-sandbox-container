# 利用者向けドキュメント案内

このページは、このリポジトリを「使う人」が次に読む文書を選ぶための入口です。
初回導入、既存環境の更新、トラブルシュート、設計理解のどこからでも入れるように
整理しています。

## まずはここから

| したいこと | 読む文書 |
| --- | --- |
| はじめて control plane をデプロイする | `docs/tutorials/first-deployment.md` |
| sample manifest の構成と編集ポイントを知りたい | `deploy/kubernetes/README.md` |
| 複数 repo / instance を Helm で管理したい | `deploy/helm/control-plane/README.md` |
| 既存環境で smoke / update を進めたい | `docs/how-to-guides/cookbook.md` |
| エラー時に症状から当たりを付けたい | `docs/reference/debug-log.md` |

## 目的別の入口

| 目的 | 文書 |
| --- | --- |
| まず README から全体像をつかみたい | `README.md` |
| runtime.env、永続 state、hook / Git policy、exec pod の kubectl 権限の path を引きたい | `docs/reference/control-plane-runtime.md` |
| なぜ session-scoped Execution Pod と Kubernetes Job を併用するのか知りたい | `docs/explanation/knowledge.md` |
| ACP ベースの Web / CLI 再設計案で、backend・frontend・CLI の責務分離を知りたい | `docs/explanation/acp-web-cli-architecture.md` |
| 現行構成に至る経緯を追いたい | `docs/explanation/history.md` |
| 複数 repo / 複数 instance の配置方法を知りたい | `deploy/helm/control-plane/README.md` |
| リポジトリ自体を改修したい | `CONTRIBUTING.md` |

## ドキュメントの役割

- Tutorial: `docs/tutorials/first-deployment.md`
  - はじめての導入を end-to-end で通す
- How-to guides: `docs/how-to-guides/cookbook.md`
  - 既存環境で特定の操作だけを進める
- Explanation: `docs/explanation/knowledge.md`,
  `docs/explanation/acp-web-cli-architecture.md`,
  `docs/explanation/history.md`
  - 仕組みや判断理由を理解する
- Deployment references: `deploy/kubernetes/README.md`,
  `deploy/helm/control-plane/README.md`
  - 導入経路ごとの manifest / values の編集ポイントを引く
- Reference: `docs/reference/control-plane-runtime.md`,
  `docs/reference/debug-log.md`
  - 正確な path、runtime surface、代表ログを引く

## 読み進め方のおすすめ

1. 全体像は `README.md`
2. 初回導入は `docs/tutorials/first-deployment.md`
3. 運用中の具体手順は `docs/how-to-guides/cookbook.md`
4. 事実関係やログを引くときは `docs/reference/*.md`
