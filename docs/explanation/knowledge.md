# Knowledge

このページは、Control Plane / Execution Plane 構成の「なぜ」を説明する Explanation です。具体的な手順は `docs/how-to-guides/cookbook.md`、失敗時のログ引きは `docs/reference/debug-log.md` を見てください。

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

## 5. state を分けて持つ理由

Control Plane では、少なくとも次を永続化対象とします。

- `~/.copilot/config.json`
- `~/.copilot/session-state`
- `~/.config/gh`
- `~/.ssh`
- `/workspace`
- `/var/lib/control-plane/rootful-podman`

一方、`~/.copilot/tmp`、rootless Podman の runtime dir / runroot、Screen socket は PVC ではなく ephemeral path に置きます。これにより stale netns や古い socket が再起動後に残りにくくなります。

current-cluster の rootful-service graphroot は既定で `/var/lib/control-plane/rootful-podman/rootful-<driver>/storage` を使います。この volume は Podman 専用の RWO 領域として分離し、init container が起動時に掃除します。runtime dir / runroot は別に `/var/tmp/control-plane/rootful-<driver>` へ寄せます。sample manifest ではここを disk-backed `emptyDir` にしているため、rootful-service 側の大きめな temp data を tmpfs-backed `/run` ではなく node 側の ephemeral storage へ逃がせます。

current-cluster の rootful-service は既定 driver を `overlay` にします。`vfs` より copy-up が軽く、PVC や node ephemeral storage の消費を抑えやすいためです。rootless overlay は選ばれた時点で `fuse-overlayfs` を前提にします。一方 rootful overlay は `/dev/fuse` がある環境でだけ `fuse-overlayfs` を使い、無い場合は kernel overlay の既定挙動へ任せます。

Podman storage は driver ごとに分離しています。`overlay` と `vfs` を混在させても DB 衝突を起こしにくくするためです。

## 6. なぜ Job の `--mount-file` は SSH/SFTP + `rclone` なのか

ConfigMap 経由の file handoff は簡単ですが、サイズ制限が厳しく、大きめの入力ファイルや Job からの write-back を扱いにくいです。そのため Kubernetes Job path の `--mount-file` は、Control Plane 自身の SSH endpoint を使って一時鍵を配り、init container が `rclone` で入力を pull し、sidecar が Job 完了後に変更ファイルを push する構成へ切り替えています。

write-back では、Job 開始時に記録した元ファイルの SHA-256 と完了時の現在値を比較します。Job 実行中に外部更新が入り、かつ Job 側も同じファイルを変えていた場合は上書きせず、競合出力を transfer staging area に退避して operator に明示します。つまり「大きいファイルを運べること」と「黙って競合を潰さないこと」を同時に優先しています。

## 7. なぜ Copilot config は ConfigMap merge で gh auth は Secret なのか

`~/.copilot/config.json` には editor preference や feature toggle のような非機密設定が入りやすく、しかも PVC 上に既存 state が残っている前提です。そのため sample manifest では `control-plane-config` ConfigMap に JSON object overlay を置き、entrypoint が既存 `~/.copilot/config.json` へ deep-merge する形にしています。これなら Pod を再作成しても PVC 上の既存設定を丸ごと消さずに、operator が足したい差分だけを宣言できます。

一方で `~/.config/gh/hosts.yml` は token を含み得るため ConfigMap へは置きません。entrypoint は `GH_HOSTS_YML_FILE` による Secret-backed file を最優先し、これが無い場合だけ `GH_GITHUB_TOKEN_FILE` から最小 `hosts.yml` を生成します。つまり gh 側は「Secret で完全指定」か「Secret token から安全に生成」の 2 択に寄せ、token を平文 ConfigMap へ流さない設計です。

## 8. bundled skill を `~/.copilot/skills` へ同期する理由

`control-plane-operations` skill は image へ同梱し、起動時に `~/.copilot/skills/control-plane-operations` へ同期します。これは `/workspace` が別リポジトリを指していても、Control Plane 固有の運用知識を常に参照可能にするためです。

今回の修正では symlink ではなく copy 同期に寄せ、`references/` を含む directory / file mode を明示的に整えています。これにより、directory traverse 権が壊れて `Permission denied` になる経路を消しています。

## 9. image 方針

image は次の優先順位で決めます。

1. 契約を満たす trusted upstream image をそのまま使う
2. 不足分だけを薄い repository-managed image で補う
3. 再利用価値が高いものだけ GHCR へ公開する

公開 tag は `latest`、commit SHA、同梱ツール version tag を併用します。再現性を優先する運用では commit SHA tag を使います。
