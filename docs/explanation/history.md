# History

このページは、現行構成へ至るまでの大きな判断をまとめた Explanation です。細かい運用は `docs/how-to-guides/cookbook.md`、現状の設計理由は `docs/explanation/knowledge.md` を参照してください。

## フェーズ 1: 共通 Control Plane を目指した段階

最初の軸は、Copilot CLI を動かす操作面を 1 つにまとめ、ローカルでも Kubernetes でも同じ感覚で使えるようにすることでした。

- `gh`、`git`、`kubectl`、SSH、Screen を 1 つの Control Plane に同居させる
- 言語別ツールチェーンは Execution Plane に分離する
- `/workspace` と認証状態を再起動後も残す

## フェーズ 2: rootless-first から current-cluster 対応へ寄った段階

当初は rootless Podman を優先しましたが、current-cluster では `spec.hostUsers: false` を前提にできず、nested user namespace 依存の経路が安定しませんでした。

そこで現行の current-cluster 向け既定値は次の形に変わりました。

- local 実行は rootless ではなく rootful remote-service fallback を使う
- 既定の実行経路は local Podman ではなく Kubernetes Job に寄せる
- `drop: ALL` を維持しつつ、SSH と Podman に必要な capability だけ再追加する

この変更により、「どこでも rootless を成立させる」よりも「この cluster で壊れにくく運用できる」ことを優先する方針が固まりました。

## フェーズ 3: session picker と interactive SSH の安定化

対話経路では、`kubectl exec` 依存を避けるために SSH と GNU Screen を正規化しました。その過程で、session picker の失敗時は通常 shell へフォールバックし、picker から入った Screen を閉じたら SSH も閉じる挙動へ整理しました。

今回の修正では、current-cluster smoke に interactive SSH login の確認を追加し、`drop: ALL` 系 profile で「接続できるがすぐ切れる」回帰を今後検知できるようにしています。

## フェーズ 4: bundled skill と current-cluster 運用知識の定着

Control Plane 固有の運用知識は repo-local docs だけでは足りず、image に同梱した skill として常に見える必要がありました。そのため `control-plane-operations` skill を image に載せ、起動時に `~/.copilot/skills` へ同期する構成にしました。

今回の修正では、symlink ではなく copy 同期へ切り替え、`references/` 配下の permission 崩れを解消しています。これにより、Control Plane 自体の運用知識も current-cluster で安定して参照できます。

## フェーズ 5: ドキュメントの Diátaxis 再編

README に背景説明、手順、トラブルシュート、設計意図が混在すると、
人間にも AI にも読みづらくなります。そこでドキュメントを
「最短導線」「目的別手順」「背景説明」「事実関係の reference」へ
分け、`docs/README.md` を入口として追加しました。

- Tutorial / quickstart: `README.md`
- Documentation map: `docs/README.md`
- How-to guides: `docs/how-to-guides/cookbook.md`
- Explanation: `docs/explanation/knowledge.md`, `docs/explanation/history.md`
- Reference: `docs/reference/control-plane-runtime.md`,
  `docs/reference/debug-log.md`

この分離により、「最初にやること」「なぜそうなっているか」
「path や hook の事実関係」「失敗ログの意味」が別々に引けるように
なりました。
