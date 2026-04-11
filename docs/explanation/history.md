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

## フェーズ 4: bundled skill の整理と最小化

Control Plane 固有の補助 workflow は repo-local docs だけでは足りず、image に同梱した skill として常に見える必要がありました。一方で runtime 委譲が gRPC 化したことで、containerized tool wrapper 系の skill は不要になりました。そこで現在は repo change delivery 系の skill だけを残し、runtime / hook 周辺は image 内の script と binary に寄せています。

同時に、symlink ではなく copy 同期へ切り替え、permission 崩れを解消しています。これにより、残した bundled skill も current-cluster で安定して参照できます。

## フェーズ 5: ドキュメントの Diátaxis 再編

README に背景説明、手順、トラブルシュート、設計意図が混在すると、
人間にも AI にも読みづらくなります。そこでドキュメントを
「最短導線」「目的別手順」「背景説明」「事実関係の reference」へ
分け、`docs/README.md` を入口として追加しました。

- Tutorial / quickstart: `README.md`
- Documentation map: `docs/README.md`
- How-to guides: `docs/how-to-guides/cookbook.md`
- Explanation: `docs/explanation/knowledge.md`, `docs/explanation/history.md`
- Deployment references: `deploy/kubernetes/README.md`,
  `deploy/helm/control-plane/README.md`
- Reference: `docs/reference/control-plane-runtime.md`,
  `docs/reference/debug-log.md`

この分離により、「最初にやること」「なぜそうなっているか」
「path や hook の事実関係」「失敗ログの意味」が別々に引けるように
なりました。

## フェーズ 6: fast execution を Rust runtime と node cache に寄せた段階

`bash` の委譲が repo の主経路になるにつれ、shell script と一時 bootstrap の
積み上げだけで lifecycle を保つのが難しくなりました。そこで fast execution の
実体は Rust 製 `runtime-tools` / `exec-api` に寄せ、session-scoped Execution Pod
の生成、token 管理、reverse `postToolUse` 転送、監査面をまとめて持たせる方向へ
切り替えました。

- Copilot CLI の `bash` tool は gRPC 経由で same-node の Execution Pod へ委譲する
- `/environment` RWO PVC を node-scoped cache とし、chroot runtime と bundled
  binary を Pod 間で再利用する
- `CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT`、command echo、scoped
  `kubectl` 権限を足し、delegated shell を観測しやすくする
- validation も `./scripts/build-test.sh` を軸にしつつ、`--build-only` の
  Buildkitd fallback と external `linter-service` を前提に整理する

この段階で、「local nested runtime を何とか延命する」よりも、「Kubernetes 上の
Execution Pod を Rust binary で安定して再利用する」ほうが repo の既定路線に
なりました。

## フェーズ 7: managed state と hook path を read-only 前提で固めた段階

fast execution が安定してくると、次に問題になったのは `~/.copilot` 配下の owner /
permission drift でした。特に ConfigMap merge 後の `config.json`、互換用
`hooks` symlink、再利用される config dir、SSH host key staging が root /
copilot の境界で崩れると、Pod 再作成後の再開性が落ちます。

- top-level の Copilot state は `copilot` user が所有する前提へそろえる
- merged `~/.copilot/config.json` も `copilot` として書き戻す
- `~/.copilot/hooks` は互換 symlink を残しつつ、差し替え自体は防ぐ
- reused config dir や SSH host key は startup 時に安全な path へ staging する
- sample docs も repo 内 build 前提ではなく、公開済み upstream image を指す方向へ寄せる

つまりこの段階では、「state を残す」だけでなく「残った state が次回起動でも
壊れない owner / mode で再利用できること」が重視されました。

## フェーズ 8: single-instance sample と multi-instance Helm chart を分けた段階

Kustomize sample は単一 instance の導入には向いていましたが、repo ごとに overlay を
複製していく運用は、shared namespace / shared session PVC / RBAC の管理が重く
なります。そこで、単一 instance の最短導線は sample manifest に残しつつ、
複数 repo や複数 instance を並べる経路は `deploy/helm/control-plane/` の
Helm chart へ切り出しました。

- Kustomize sample は「初回導入」「構成を読む reference」の役割に寄せる
- Helm chart は shared namespace / jobs namespace / session PVC /
  ConfigMap / Secret / RBAC を共通化しつつ、instance ごとに workspace PVC、
  Service、runtime env、auth、config を override できる
- session PVC は共有しつつ、state は `instances/<name>/...` 配下へ分けて
  複数 control plane を同居させる
- user-facing docs も「まず sample か Helm か」を入口で選べるようにする

この変更により、「shipped sample を 1 つ整えて使う repo」から、「同じ cluster に
複数 repo の control plane を並べて管理できる repo」へ性格が広がりました。
