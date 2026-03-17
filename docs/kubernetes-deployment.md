# Kubernetes deployment example

このドキュメントは、Control Plane を Kubernetes 上で動かすための最小テンプレートと、
その前提条件を説明します。テンプレート本体は
`deploy/kubernetes/control-plane.example.yaml` にあります。

リポジトリ全体の概要、quick start、rootless Podman の背景説明は `README.md` を、
契約レベルの要件は `docs/requirements.md` を参照してください。ここでは
Kubernetes manifest と運用時の前提に絞って説明します。

## 含まれるもの

- Control Plane 用 namespace
- Job 用 namespace
- Control Plane Pod 用 ServiceAccount
- Job 実行 Pod 用 ServiceAccount
- Control Plane から Job namespace を操作する RBAC
- SSH 公開鍵と任意の Copilot token 用 Secret
- Control Plane 状態用 PersistentVolumeClaim
- SSH 用 LoadBalancer Service
- Control Plane Deployment
- PVC 上に永続化される SSH host key

## 使い方

1. `image` を使いたい Control Plane イメージに合わせます。公開既定値は `ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest` です。再現性を優先する場合は `latest` ではなく commit SHA tag を使ってください。
2. `control-plane-auth` Secret の `ssh-public-key` を利用者の公開鍵に置き換えます。`copilot-github-token` は任意で、設定しても login shell には export されず、Copilot 起動時にだけ `--secret-env-vars=COPILOT_GITHUB_TOKEN` 経由で渡されます。
3. 必要なら `CONTROL_PLANE_GIT_USER_NAME` と `CONTROL_PLANE_GIT_USER_EMAIL` を Deployment の `env` に追加します。entrypoint が `~/.gitconfig` と GitHub credential helper を事前設定します。
4. `storageClassName` と PVC サイズをクラスタに合わせて調整します。サンプルの PVC は Control Plane 状態と `/workspace` を永続化します。
5. 必要に応じて Job 用の image pull policy、CPU、メモリ上限を調整します。

## namespace 構成

サンプルは、Control Plane と Job を別 namespace に分けます。

- Control Plane: `copilot-sandbox`
- Job: `copilot-sandbox-jobs`

Control Plane Pod 自体は `copilot-sandbox` の ServiceAccount を使います。Job を作成・削除・監視する RBAC は Job namespace 側に置き、RoleBinding の subject だけ Control Plane namespace の ServiceAccount を参照します。
この RBAC には、`--mount-file` 用の一時 ConfigMap を作成・削除する権限も含めます。

Job Pod が使う `serviceAccountName` は Job namespace 側のものです。Pod spec の `serviceAccountName` は cross-namespace 参照できないため、Job 用 ServiceAccount は別に作っています。

## securityContext の考え方

サンプルは `privileged: false` のまま SSH / Copilot を成立させる least-privilege 構成です。

- Pod `securityContext.fsGroup: 1000`
- container `allowPrivilegeEscalation: true`
- container `capabilities.drop: [ALL]`
- container `capabilities.add: [CHOWN, DAC_OVERRIDE, FOWNER, SETFCAP, SETGID, SETUID, SYS_CHROOT]`
- `seccompProfile: RuntimeDefault`

各 capability の役割や rootless Podman の背景は `README.md` にもまとめています。
ここでは manifest に直接効く前提だけを残しています。

`drop: ALL` だけでは SSH は成立しません。`sshd` の privilege separation には `SETUID` / `SETGID` / `SYS_CHROOT` が必要で、entrypoint の初期化や state volume の ownership 調整には `CHOWN` / `DAC_OVERRIDE` / `FOWNER` も必要です。サンプル manifest は、Linux 5.12+ の rootless Podman で UID 0 mapping に必要になる `SETFCAP` も追加しています。現在の entrypoint は SSH / state 初期化に必須の capability が欠けていると起動直後に明示的なエラーを出して停止します。

それでも GNU Screen session picker が runtime 依存の理由で起動できない場合があるため、現在は picker の失敗時に通常の login shell へフォールバックします。これにより、picker の問題で SSH 接続そのものがすぐ切れにくくなっています。

## local Podman について

Kubernetes 上の local nested Podman / Kind は、引き続き best-effort です。

Control Plane イメージ内の `podman` と `docker` は `control-plane-podman` wrapper への
symlink です。`cannot clone: Operation not permitted` や
`invalid internal status ... cannot re-exec process` を検出すると、
outer runtime 側の制約であることと `k8s-job` / GitHub Actions / host runner への
切り替え候補を追加で案内します。

- rootless Podman は outer host / runtime 側の user namespace、`newuidmap` / `newgidmap`、`/dev/fuse` に依存します
- Linux 5.12+ では UID 0 mapping のため `SETFCAP` も必要です
- `securityContext.privileged: true` でも outer runtime が nested user namespace を禁止していれば `cannot set user namespace` で失敗します
- そのため、サンプルの既定経路は `CONTROL_PLANE_RUN_MODE=k8s-job` です

どうしても Pod 内ローカル実行を優先したい場合だけ `CONTROL_PLANE_RUN_MODE=auto` へ切り替えるか `control-plane-run --mode podman` を使ってください。ただし、`privileged` は十分条件ではありません。

Podman storage は driver ごとに分離しています。

- overlay: `~/.copilot/containers/overlay/storage`
- vfs: `~/.copilot/containers/vfs/storage`

これにより、`/dev/fuse` の有無や securityContext の変更で driver が切り替わっても、以前の DB と衝突して `User-selected graph driver "vfs" overwritten by graph driver "overlay" from database` のようなエラーを起こしにくくしています。

## Job に `/workspace` を見せる方法

Control Plane namespace の PVC は、そのままでは Job namespace の Pod に mount できません。別 namespace に Job を分ける場合、`/workspace` の扱いは次の 2 パターンに分かれます。

1. 大きい repo や継続的な作業が必要なら、Job namespace 側にも同じ内容を見せる shared storage を別途用意し、`CONTROL_PLANE_JOB_WORKSPACE_PVC` を設定する
2. 小さい補助ファイルだけで足りるなら、`control-plane-run --mount-file ...` を使って ConfigMap 経由で渡す

サンプル manifest では、shared storage の実装方式がクラスタ依存なので `CONTROL_PLANE_JOB_WORKSPACE_PVC` はコメントアウトしています。必要な環境だけ明示的に有効化してください。

## 小さいファイルの受け渡し

`control-plane-run` と `k8s-job-start` は `--mount-file SRC[:DEST]` をサポートします。これは小さいローカルファイルを ConfigMap に詰めて Job へ read-only mount するためのものです。

- 既定 mount path: `/var/run/control-plane/job-inputs`
- `DEST` はその配下の相対パス
- 既定では raw file 合計約 `750000` bytes を超える payload は拒否します
- 大きい payload には向きません

例:

```bash
control-plane-run \
  --mode k8s-job \
  --namespace copilot-sandbox-jobs \
  --mount-file ./script.sh:scripts/script.sh \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke exec bash -lc \
     'bash /var/run/control-plane/job-inputs/scripts/script.sh'
```

`--mount-file` は local Podman 経路でも同じ mount path にファイルを並べます。小さい補助スクリプトや設定ファイルにはこれを使い、repo 全体や大きい build context は shared storage や外部 artifact ストアを使ってください。

## 主要な env

```yaml
- name: CONTROL_PLANE_K8S_NAMESPACE
  value: copilot-sandbox
- name: CONTROL_PLANE_JOB_NAMESPACE
  value: copilot-sandbox-jobs
- name: CONTROL_PLANE_RUN_MODE
  value: k8s-job
- name: CONTROL_PLANE_JOB_SERVICE_ACCOUNT
  value: control-plane-job
- name: CONTROL_PLANE_JOB_INPUT_MOUNT_PATH
  value: /var/run/control-plane/job-inputs
# Optional: namespace-local shared workspace for Jobs
# - name: CONTROL_PLANE_JOB_WORKSPACE_PVC
#   value: control-plane-workspace-pvc
# - name: CONTROL_PLANE_JOB_WORKSPACE_SUBPATH
#   value: workspace
```

## よくある詰まりどころ

### `drop: ALL` にしたら SSH できない

`capabilities.add` に `CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `SETFCAP` / `SETGID` / `SETUID` / `SYS_CHROOT` を戻してください。SSH 自体に最低限必要なのは `CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `SETGID` / `SETUID` / `SYS_CHROOT` で、`SETFCAP` は local rootless Podman 向けです。session picker が失敗しても現在は通常 shell へフォールバックしますが、picker 自体を完全に避けたい場合は `CONTROL_PLANE_DISABLE_SESSION_PICKER=1` を設定してください。

### privileged でも Podman が `cannot set user namespace` で失敗する

Pod 内ではなく outer runtime の制約です。rootless Podman を完全には保証できません。`control-plane-podman` / build-test の診断はこのケースを明示的に案内するようになっていますが、解決には outer runtime 側の user namespace 許可が必要です。`control-plane-run --mode k8s-job` か GitHub Actions / host runner を使ってください。背景説明は `README.md` の「Rootless Podman / nested runtime の扱い」も参照してください。

### securityContext を変えたら overlay / vfs の警告が出た

現在は storage を driver ごとに分離しているため、古い image や古い state が残っている場合を除き、同じ `$HOME/.copilot/containers/storage` を共有していた頃のような衝突は起きにくくなっています。古い state を引きずっている場合は、永続 volume 上の Podman state を整理してください。

## 補足

- サンプルの Service は `LoadBalancer` です。`EXTERNAL-IP` が付く前でも `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox` で SSH できます。
- Copilot CLI の multiline shortcut (`Shift+Enter`) は upstream 側で Kitty protocol 対応 terminal を前提とします。`tmux` / GNU Screen 越しでは安定しない場合があるため、必要なら `Ctrl+G` で外部 editor を使ってください。
- `control-plane-operations` skill は image に同梱され、起動時に `~/.copilot/skills/control-plane-operations` へ同期されます。
