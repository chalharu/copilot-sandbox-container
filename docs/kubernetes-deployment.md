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
2. `control-plane-auth` Secret の `ssh-public-key` を利用者の公開鍵に置き換えます。`copilot-github-token` は任意で、設定しても login shell には export されず、Copilot 起動時にだけ `--secret-env-vars=COPILOT_GITHUB_TOKEN` 経由で渡されます。DHI pull 用の `dockerhub-username` / `dockerhub-token` も任意で、entrypoint が private file に退避して `scripts/prepare-dhi-images.sh` から file path 経由で参照できるようにします。
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

サンプルは `privileged: false` のまま SSH / Copilot と local Podman を成立させる
current-cluster 互換構成です。

このクラスタでは `spec.hostUsers: false` の Pod/Job が `ContainerCreating` から進まなかったため、
sample manifest は Pod user namespace へ依存しません。代わりに
`CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service` を使い、control-plane container の中で
rootful Podman remote service を立てて `copilot` ユーザーから `CONTAINER_HOST` 経由で使います。

- Pod `securityContext.fsGroup: 1000`
- container `allowPrivilegeEscalation: true`
- container `capabilities.drop: [ALL]`
- container `capabilities.add: [CHOWN, DAC_OVERRIDE, FOWNER, KILL, MKNOD, NET_ADMIN, SETFCAP, SETGID, SETPCAP, SETUID, SYS_ADMIN, SYS_CHROOT]`
- control-plane container `seccompProfile: Unconfined`
- control-plane container `appArmorProfile.type: Unconfined`

各 capability の役割や rootless Podman の背景は `README.md` にもまとめています。
ここでは manifest に直接効く前提だけを残しています。

`drop: ALL` だけでは SSH は成立しません。`sshd` の privilege separation には
`SETUID` / `SETGID` / `SYS_CHROOT` が必要で、entrypoint の初期化や state volume の ownership
調整には `CHOWN` / `DAC_OVERRIDE` / `FOWNER` も必要です。current-cluster の local Podman
fallback では、さらに `KILL` / `MKNOD` / `NET_ADMIN` / `SETFCAP` / `SETPCAP` / `SYS_ADMIN`
も必要でした。現在の entrypoint は mode に応じて必須 capability が欠けていると、
起動直後に明示的なエラーを出して停止します。

rootless Podman をどうしても続けたい場合だけ、`spec.hostUsers: false` と
`CONTROL_PLANE_LOCAL_PODMAN_MODE=rootless` へ切り替えてください。ただし、このクラスタ実測では
`hostUsers: false` Pod 自体が起動しませんでした。OCI runtime / CRI / idmap mount / projected
volume の組み合わせがそろっている cluster でのみ有効化してください。

それでも GNU Screen session picker が runtime 依存の理由で起動できない場合があるため、現在は picker の失敗時に通常の login shell へフォールバックします。一方、picker から入った Screen を `exit` した場合は SSH もそのまま閉じ、余計な login shell へ戻らないようにしています。

## local Podman について

Kubernetes 上の local nested Podman / Kind は、引き続き best-effort です。ただし current
cluster 向け sample manifest は rootless ではなく **rootful remote-service fallback** を使います。

Control Plane イメージ内の `podman` と `docker` は `control-plane-podman` wrapper への
symlink です。`cannot clone: Operation not permitted` や
`invalid internal status ... cannot re-exec process` を検出すると、
outer runtime 側の制約であることに加え、Pod user namespace が有効かどうか、
`podman system migrate` で回復できる stale state かどうかも追加で案内します。

- current-cluster sample は `CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service` を使います
- wrapper は current-cluster fallback 中だけ `CONTAINER_HOST` / `DOCKER_HOST` を rootful service socket へ向け、`podman run` に `--cgroups=disabled --network=host` を既定で足します
- rootful service は `vfs` storage driver を使うので `/dev/fuse` なしでも動きます
- `securityContext.privileged: false` のままでも、上記 capability と unconfined seccomp/AppArmor をそろえれば current cluster で `podman run` が通ります
- rootless profile に戻す場合だけ outer host / runtime 側の user namespace、`newuidmap` / `newgidmap`、`/dev/fuse`、必要に応じて `/dev/net/tun` が重要になります
- そのため、サンプルの既定経路は `CONTROL_PLANE_RUN_MODE=k8s-job` です

どうしても Pod 内ローカル実行を優先したい場合だけ `CONTROL_PLANE_RUN_MODE=auto` へ切り替えるか
`control-plane-run --mode podman` を使ってください。current-cluster sample では local Podman は
rootful remote service 経路へ流れます。rootless profile に戻す場合は `privileged` は十分条件ではなく、
`hostUsers: false`、outer runtime の userns 許可、必要に応じて `/dev/fuse` / `/dev/net/tun`
までそろえてください。

Podman storage は driver ごとに分離しています。

- overlay: `~/.copilot/containers/overlay/storage`
- vfs: `~/.copilot/containers/vfs/storage`

これにより、`/dev/fuse` の有無や securityContext の変更で driver が切り替わっても、以前の DB と衝突して `User-selected graph driver "vfs" overwritten by graph driver "overlay" from database` のようなエラーを起こしにくくしています。Podman の runtime dir / runroot / Screen socket は PVC ではなく `/run/user/1000` や `/tmp` のような ephemeral path を使うため、Pod 再起動後の stale netns や `podman run` 完了後にシェルへ戻らない症状も起こしにくくしています。

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

`capabilities.add` に `CHOWN` / `DAC_OVERRIDE` / `FOWNER` / `KILL` / `SETGID` / `SETUID` /
`SYS_CHROOT` を戻してください。current-cluster sample の local Podman fallback まで含めるなら、
さらに `MKNOD` / `NET_ADMIN` / `SETFCAP` / `SETPCAP` / `SYS_ADMIN` も戻してください。
sample manifest どおり control-plane container を `seccompProfile: Unconfined` と
`appArmorProfile.type: Unconfined` にし、session picker を完全に避けたい場合は
`CONTROL_PLANE_DISABLE_SESSION_PICKER=1` を設定してください。

### privileged でも Podman が `cannot set user namespace` で失敗する

Pod 内ではなく outer runtime の制約です。current cluster では rootless Podman の前提である
`spec.hostUsers: false` がそもそも使えなかったため、sample manifest は rootful remote-service
fallback を既定にしました。rootless に戻したい場合は `cat /proc/self/uid_map` で Pod user namespace
が効いているか確認し、1 行目が `0 0 4294967295` のままなら `spec.hostUsers: false` が効いていないと
考えてください。そこが解消済みでも失敗する場合は outer runtime 側の userns / `newuidmap` /
`newgidmap` / seccomp / AppArmor 条件が足りていません。

### securityContext を変えたら overlay / vfs の警告が出た

現在は storage を driver ごとに分離しているため、古い image や古い state が残っている場合を除き、同じ `$HOME/.copilot/containers/storage` を共有していた頃のような衝突は起きにくくなっています。古い state を引きずっている場合は、永続 volume 上の Podman state を整理してください。

## 補足

- current cluster 上で sample manifest 相当の rootful-service Podman / interactive `-it` / SSH 回帰をまとめて確かめたい場合は、`scripts/test-k8s-job.sh` を使ってください。現在の Pod image を既定値として拾い、修正済みスクリプトを ConfigMap 経由で一時 Job へ注入して `control-plane-entrypoint` / `control-plane-podman` / localhost SSH の smoke を実行します。
- サンプルの Service は `LoadBalancer` です。`EXTERNAL-IP` が付く前でも `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox` で SSH できます。
- SSH login shell は使えない `TERM` を `xterm-256color` / `xterm` へ補正し、`xterm-color` のような low-color term も 256 色 terminfo へ引き上げます。GNU Screen では 10000 行 scrollback と mouse tracking を既定化しています。
- Copilot CLI の multiline shortcut (`Shift+Enter`) は upstream 側で Kitty protocol 対応 terminal を前提とします。`tmux` / GNU Screen 越しでは安定しない場合があるため、必要なら `Ctrl+G` で外部 editor を使ってください。
- `control-plane-operations` skill は image に同梱され、起動時に `~/.copilot/skills/control-plane-operations` へ同期されます。
