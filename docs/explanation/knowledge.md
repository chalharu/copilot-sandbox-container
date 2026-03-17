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

- `~/.copilot`
- `~/.config/gh`
- `~/.ssh`
- `/workspace`

一方、Podman の runtime dir、runroot、Screen socket は PVC ではなく ephemeral path に置きます。これにより stale netns や古い socket が再起動後に残りにくくなります。

Podman storage は driver ごとに分離しています。`overlay` と `vfs` を混在させても DB 衝突を起こしにくくするためです。

## 6. bundled skill を `~/.copilot/skills` へ同期する理由

`control-plane-operations` skill は image へ同梱し、起動時に `~/.copilot/skills/control-plane-operations` へ同期します。これは `/workspace` が別リポジトリを指していても、Control Plane 固有の運用知識を常に参照可能にするためです。

今回の修正では symlink ではなく copy 同期に寄せ、`references/` を含む directory / file mode を明示的に整えています。これにより、directory traverse 権が壊れて `Permission denied` になる経路を消しています。

## 7. image 方針

image は次の優先順位で決めます。

1. 契約を満たす trusted upstream image をそのまま使う
2. 不足分だけを薄い repository-managed image で補う
3. 再利用価値が高いものだけ GHCR へ公開する

公開 tag は `latest`、commit SHA、同梱ツール version tag を併用します。再現性を優先する運用では commit SHA tag を使います。
