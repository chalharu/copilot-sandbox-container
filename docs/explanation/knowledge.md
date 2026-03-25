# Knowledge

このページは、Control Plane / Execution Plane 構成の「なぜ」を説明する
Explanation です。具体的な手順は `docs/how-to-guides/cookbook.md`、
runtime / path / hook の事実関係は
`docs/reference/control-plane-runtime.md`、失敗時のログ引きは
`docs/reference/debug-log.md` を見てください。

## 1. 2 層構成を採る理由

このリポジトリは、Control Plane と Execution Plane を分けます。

- **Control Plane** は Copilot CLI、`gh`、`git`、`kubectl`、SSH、GNU Screen、Podman wrapper を持つ長寿命の操作面
- **Execution Plane** は実際の build / test / lint / 実行を担う短命の作業面

この分離により、対話状態や認証状態は Control Plane に残しつつ、言語別ツールチェーンは Execution Plane に閉じ込められます。

## 2. `kubectl exec` ではなく SSH + GNU Screen を主経路にする理由

Control Plane を Kubernetes Pod で動かす場合、`kubectl exec` は保守用には便利ですが、長い対話やネットワーク断に弱いです。このリポジトリでは SSH login を正規経路にし、その上で GNU Screen を使ってセッションを再開可能にします。

session picker は interactive login の入口です。picker が動けば既存 session へ再接続し、必要なら新しい shell や Copilot session を起動します。picker が runtime 依存で失敗する場合だけ通常 shell へフォールバックします。

## 3. short / long を分ける理由

`control-plane-run` は、同じ CLI から 2 種類の実行先を選べるようにしています。

- `--execution-hint short`: 速さと対話性を優先する local execution
- `--execution-hint long`: ログ収集、再試行、隔離を優先する Kubernetes Job

current-cluster では `CONTROL_PLANE_RUN_MODE=k8s-job` を既定にし、local Podman は明示 opt-in に寄せています。これは「local も動く」ことより「壊れにくい既定値」を優先しているためです。

## 4. なぜ current-cluster では rootful-service fallback なのか

設計の第一候補は rootless Podman です。ただし current-cluster では `spec.hostUsers: false` の Pod が安定して起動せず、nested user namespace 前提を置けませんでした。そのため、sample manifest と current-cluster smoke では次の構成を既定にしています。

- `CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service`
- `CONTROL_PLANE_RUN_MODE=k8s-job`
- `capabilities.drop: [ALL]` のうえで必要 capability だけを再追加
- `seccompProfile: Unconfined` と `appArmorProfile.type: Unconfined`
- rootful-service build では `CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot`

この構成は least-privilege ではありますが、rootless の完全互換ではありません。したがって current-cluster の local nested Podman / Kind は今も best-effort 扱いです。

## 5. sample manifest の state をどう分けるか

sample manifest の既定値では、永続化を 3 つの PVC に分けます。

- RWX の copilot session PVC
- RWO の `/workspace` PVC
- RWOP の dedicated `sccache-dist` PVC（5Gi）

copilot session PVC には `~/.copilot/config.json`、`~/.copilot/command-history-state.json`、`~/.copilot/session-state`、`~/.copilot/session-state/audit/audit-log.db`、`~/.copilot/session-state/audit/audit-analysis.db`、`~/.config/gh`、`~/.ssh`、`/var/lib/control-plane/ssh-host-keys` をまとめます。これで session picker、GitHub 認証、SSH 鍵、Copilot の設定、監査ログ、監査分析結果は Pod 再作成後も残せます。

一方で long-running Rust Job の `sccache` は、Job ごとに PVC を mount せず
`sccache-dist` Service 越しに builder sidecar へ送ります。shared cache 本体は
`ReadWriteOncePod` の dedicated PVC へ寄せ、1 Pod attachment のまま複数 Job
から再利用しやすくし、shared `/workspace` PVC を巨大な object cache で
埋めないようにします。sample manifest では 5Gi claim に対して
`SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE=4294967296` を与え、メタデータや一時
ファイル向けの headroom を残します。dist mode を切った場合だけ、Job は
`/workspace/cache/<repo>/<branch>/sccache` へ local fallback します。

一方、`~/.copilot/tmp`、Screen socket、rootless Podman の graphroot / runtime dir / runroot、rootful-service の graphroot cache は PVC ではなく ephemeral path に置きます。rootless Podman の graphroot は `/var/tmp/control-plane/rootless-podman/<driver>/storage` へ寄せ、`~/.copilot/containers` には互換用 symlink だけを残します。特に rootful-service の graphroot は `/var/lib/control-plane/rootful-podman/rootful-<driver>/storage` を使いつつ、sample manifest ではその背後を disposable な `emptyDir` にしているため、再作成可能な Podman cache が persistent volume を食い潰しません。runtime dir / runroot は引き続き `/var/tmp/control-plane/rootful-<driver>` へ寄せ、disposable な runtime cache 側へまとめます。監査ログだけは追跡対象なので `~/.copilot/session-state/audit/audit-log.db` に固定し、`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）を超えた tool hook のタイミングで古いレコードから削除して、おおむね上限の 3/4 件まで戻します。

current-cluster の rootful-service は既定 driver を `overlay` にします。`vfs` より copy-up が軽く、PVC や node ephemeral storage の消費を抑えやすいためです。rootless overlay は選ばれた時点で `fuse-overlayfs` を前提にします。一方 rootful overlay は `/dev/fuse` がある環境でだけ `fuse-overlayfs` を使い、無い場合は kernel overlay の既定挙動へ任せます。

Podman storage は driver ごとに分離しています。`overlay` と `vfs` を混在させても DB 衝突を起こしにくくするためです。

## 6. なぜ Job の `--mount-file` は SSH/SFTP + `rclone` なのか

ConfigMap 経由の file handoff は簡単ですが、サイズ制限が厳しく、大きめの入力ファイルや Job からの write-back を扱いにくいです。そのため Kubernetes Job path の `--mount-file` は、Control Plane 自身の SSH endpoint を使って一時鍵を配り、init container が `rclone` で入力を pull し、sidecar が Job 完了後に変更ファイルを push する構成へ切り替えています。

write-back では、Job 開始時に記録した元ファイルの SHA-256 と完了時の現在値を比較します。Job 実行中に外部更新が入り、かつ Job 側も同じファイルを変えていた場合は上書きせず、競合出力を transfer staging area に退避して operator に明示します。つまり「大きいファイルを運べること」と「黙って競合を潰さないこと」を同時に優先しています。

## 7. なぜ Copilot config は ConfigMap merge で gh auth は Secret なのか

`~/.copilot/config.json` には editor preference や feature toggle のような非機密設定が入りやすく、しかも PVC 上に既存 state が残っている前提です。そのため sample manifest では `control-plane-config` ConfigMap に JSON object overlay を置き、entrypoint が既存 `~/.copilot/config.json` へ deep-merge する形にしています。これなら Pod を再作成しても PVC 上の既存設定を丸ごと消さずに、operator が足したい差分だけを宣言できます。`controlPlane.auditAnalysis` 配下の target repository URL や evidence threshold も同じ理由で ConfigMap 側に置くのが自然です。

一方で namespace / PVC / Job 実行モード / file path のような「ただの文字列 env」は JSON overlay と性質が違います。sample manifest ではこれらを `control-plane-env` ConfigMap へ分け、Deployment から `envFrom` でまとめて読み込みます。こうしておくと `copilot-config.json` のような file-content key を process 環境変数として投影せずに済み、manifest の `env:` 行数も抑えられます。

一方で `~/.config/gh/hosts.yml` は token を含み得るため ConfigMap へは置きません。entrypoint は `GH_HOSTS_YML_FILE` による Secret-backed file を最優先し、これが無い場合だけ `GH_GITHUB_TOKEN_FILE` から最小 `hosts.yml` を生成します。つまり gh 側は「Secret で完全指定」か「Secret token から安全に生成」の 2 択に寄せ、token を平文 ConfigMap へ流さない設計です。

## 8. bundled skill を `~/.copilot/skills` へ同期する理由

`control-plane-operations` や `audit-log-analysis` のような bundled skill は image へ同梱し、起動時に `~/.copilot/skills/` へ同期します。これは `/workspace` が別リポジトリを指していても、Control Plane 固有の運用知識や監査分析 workflow を常に参照可能にするためです。

今回の修正では symlink ではなく copy 同期に寄せ、`references/` を含む directory / file mode を明示的に整えています。これにより、directory traverse 権が壊れて `Permission denied` になる経路を消しています。

## 9. image 方針

image は次の優先順位で決めます。

1. 契約を満たす trusted upstream image をそのまま使う
2. 不足分だけを薄い repository-managed image で補う
3. 再利用価値が高いものだけ GHCR へ公開する

公開 tag は `latest`、commit SHA、同梱ツール version tag を併用します。再現性を優先する運用では commit SHA tag を使います。
