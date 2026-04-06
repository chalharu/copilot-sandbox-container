# Knowledge

このページは、Control Plane / Execution Plane 構成の「なぜ」を説明する
Explanation です。具体的な手順は `docs/how-to-guides/cookbook.md`、
runtime / path / hook の事実関係は
`docs/reference/control-plane-runtime.md`、失敗時のログ引きは
`docs/reference/debug-log.md` を見てください。

## 1. 2 層構成を採る理由

このリポジトリは、Control Plane と Execution Plane を分けます。

- **Control Plane** は Copilot CLI、`kubectl`、SSH、GNU Screen、bundled hook/runtime を持つ長寿命の操作面
- **Execution Plane** は実際の build / test / lint / 実行を担う短命の作業面

この分離により、対話状態や認証状態は Control Plane に残しつつ、言語別ツールチェーンは Execution Plane に閉じ込められます。

## 2. `kubectl exec` ではなく SSH + GNU Screen を主経路にする理由

Control Plane を Kubernetes Pod で動かす場合、`kubectl exec` は保守用には便利ですが、長い対話やネットワーク断に弱いです。このリポジトリでは SSH login を正規経路にし、その上で GNU Screen を使ってセッションを再開可能にします。

session picker は interactive login の入口です。picker が動けば既存 session へ再接続し、必要なら新しい shell や Copilot session を起動します。picker が runtime 依存で失敗する場合だけ通常 shell へフォールバックします。

## 3. session fast path と Job path を分ける理由

`control-plane-run` は operator が explicit に叩く command を Kubernetes Job
へ送る経路です。一方で Copilot CLI 自身の `bash` tool は、
`CONTROL_PLANE_FAST_EXECUTION_ENABLED=1` のとき bundled `preToolUse` hook が
session-scoped Execution Pod へ書き換えます。この Pod は同じ `/workspace` PVC
を mount し、session 中は再利用され、`sessionEnd` と OwnerReference の両方で
cleanup されます。

つまりこの repo は「対話中の Copilot bash は session fast path」「operator が
明示的に叩く command は Kubernetes Job」という二経路を持ちます。どちらも
Kubernetes 上で動かすことで、権限分離・再現性・異常時の影響範囲をそろえます。

## 4. なぜ local nested runtime を既定にしないのか

Control Plane Pod の中でさらに local container runtime を抱える構成は、outer
runtime の制約、capability 要件、state cleanup、resource 競合を増やします。
この repo では「手元でもたまたま動く」より「Kubernetes 上で壊れにくい既定値」
を優先し、sample manifest と operator 向け command を Kubernetes 経路へ
寄せています。

## 5. sample manifest の state をどう分けるか

sample manifest の既定値では、永続化を 3 つの PVC に分けます。

- RWX の copilot session PVC
- RWO の `/workspace` PVC
- RWO の dedicated `sccache` object-store PVC（5Gi）

copilot session PVC には `~/.copilot/config.json`、`~/.copilot/command-history-state.json`、`~/.copilot/session-state`、`~/.copilot/session-state/audit/audit-log.db`、`~/.config/gh`、`~/.ssh`、`/var/lib/control-plane/ssh-host-keys` をまとめます。これで session picker、GitHub 認証、SSH 鍵、Copilot の設定、監査ログは Pod 再作成後も残せます。

`~/.copilot/session-state/session-exec.json` も同じ PVC に置き、session key ごとの
Execution Pod 名、Pod IP、owner metadata、node name を記録します。

一方で long-running Rust Job の `sccache` は、Job ごとに PVC を mount せず
standalone Garage Deployment へ Service 越しに送ります。shared cache 本体は
`ReadWriteOnce` の dedicated PVC へ寄せ、shared `/workspace` PVC を巨大な
object cache で埋めないようにします。sample manifest では 5Gi claim に対して
Garage bucket quota を `4294967296` bytes に抑え、メタデータや一時
ファイル向けの headroom を残します。古い cache object は S3 lifecycle の
expiration で自動削除します。object-store mode を切った場合も、Job の
`cargo` / `rustup` / `target` / `sccache` は
`/var/tmp/containerized-rust/<repo>/<branch>/...` の ephemeral path を使い、
`/workspace` 側には Rust cache を残しません。

一方、`~/.copilot/tmp`、Screen socket、`/var/tmp/control-plane` 配下の一時
作業領域、Rust の `cargo-target` などは PVC ではなく ephemeral path に置きます。
再生成できる cache や temp state を persistent volume から分離し、session PVC
と `/workspace` PVC には再開に必要な state だけを残すためです。監査ログだけは
追跡対象なので `~/.copilot/session-state/audit/audit-log.db` に固定し、
`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）を超えた tool hook の
タイミングで古いレコードから削除して、おおむね上限の 3/4 件まで戻します。

## 6. なぜ Job の `--mount-file` は SSH/SFTP + `rclone` なのか

ConfigMap 経由の file handoff は簡単ですが、サイズ制限が厳しく、大きめの入力ファイルや Job からの write-back を扱いにくいです。そのため Kubernetes Job path の `--mount-file` は、Control Plane 自身の SSH endpoint を使って一時鍵を配り、init container が `rclone` で入力を pull し、sidecar が Job 完了後に変更ファイルを push する構成へ切り替えています。

write-back では、Job 開始時に記録した元ファイルの SHA-256 と完了時の現在値を比較します。Job 実行中に外部更新が入り、かつ Job 側も同じファイルを変えていた場合は上書きせず、競合出力を transfer staging area に退避して operator に明示します。つまり「大きいファイルを運べること」と「黙って競合を潰さないこと」を同時に優先しています。

## 7. なぜ Copilot config は ConfigMap merge で gh auth は Secret なのか

`~/.copilot/config.json` には editor preference や feature toggle のような非機密設定が入りやすく、しかも PVC 上に既存 state が残っている前提です。そのため sample manifest では `control-plane-config` ConfigMap に JSON object overlay を置き、entrypoint が既存 `~/.copilot/config.json` へ deep-merge する形にしています。これなら Pod を再作成しても PVC 上の既存設定を丸ごと消さずに、operator が足したい差分だけを宣言できます。

一方で namespace / PVC / file path のような「ただの文字列 env」は JSON overlay と性質が違います。sample manifest ではこれらを `control-plane-env` ConfigMap へ分け、Deployment から `envFrom` でまとめて読み込みます。こうしておくと `copilot-config.json` のような file-content key を process 環境変数として投影せずに済み、manifest の `env:` 行数も抑えられます。

一方で `~/.config/gh/hosts.yml` は token を含み得るため ConfigMap へは置きません。entrypoint は `GH_HOSTS_YML_FILE` による Secret-backed file を最優先し、これが無い場合だけ `GH_GITHUB_TOKEN_FILE` から最小 `hosts.yml` を生成します。つまり gh 側は「Secret で完全指定」か「Secret token から安全に生成」の 2 択に寄せ、token を平文 ConfigMap へ流さない設計です。さらに mounted Secret は `/run/control-plane-auth` に一時的に現れるだけで、interactive shell からの direct read は policy で拒否し、startup 後は `ssh`・`gh`・`control-plane-copilot` のような surface だけを使わせます。

## 8. bundled skill を `~/.copilot/skills` へ同期する理由

repo change delivery 系の bundled skill は image へ同梱し、起動時に `~/.copilot/skills/` へ同期します。これは `/workspace` が別リポジトリを指していても、Control Plane 固有の delivery workflow を常に参照可能にするためです。

今回の修正では symlink ではなく copy 同期に寄せ、`references/` を含む directory / file mode を明示的に整えています。これにより、directory traverse 権が壊れて `Permission denied` になる経路を消しています。

## 9. image 方針

image は次の優先順位で決めます。

1. 契約を満たす trusted upstream image をそのまま使う
2. 不足分だけを薄い repository-managed image で補う
3. 再利用価値が高いものだけ GHCR へ公開する

公開 tag は `latest`、commit SHA、同梱ツール version tag を併用します。再現性を優先する運用では commit SHA tag を使います。
