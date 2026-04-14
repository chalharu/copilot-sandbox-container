# Debug log reference

このページは、current-cluster と Control Plane 周辺で実際に重要になる
ログ断片を引くための Reference です。手順は
`docs/how-to-guides/cookbook.md` を参照してください。背景説明は
`docs/explanation/knowledge.md`、runtime / path の事実関係は
`docs/reference/control-plane-runtime.md` を参照してください。

このリポジトリの rootful-service sample では、local Podman の graphroot を既定で
`/var/lib/control-plane/rootful-podman/rootful-overlay/storage` に置きます。
runtime dir は `/var/tmp/control-plane/rootful-overlay` へ寄せます。graphroot の
背後は disposable な `emptyDir` cache です。runtime dir も disk-backed
`emptyDir` を想定します。Pod 再作成時に再生成できる local image store を
persistent volume から切り離しています。
fast-exec Execution Pod の `/tmp` と `/var/tmp` も同様に generic ephemeral volume
で切り離します。storage class と合計サイズは
`CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS` /
`CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_SIZE` で制御します。storage class を
省略した場合は cluster の default StorageClass を使います。
Rust の `cargo-target` は `/root/.cargo/config.toml` 経由で
`/var/tmp/control-plane/cargo-target` へ寄せます。

## Quick index by symptom

| Symptom | Section |
| --- | --- |
| `Permission denied` で bundled skill が読めない | [§1](#1-bundled-skill-が読めない) |
| capability 不足で起動時に止まる | [§2](#2-capability-が足りず起動時に止まる) |
| SSH が切れる / `cleanup_exit` が出る | [§3](#3-interactive-ssh-で切れる--sshd-cleanup-警告が出る) |
| rootless Podman の user namespace error | [§4](#4-rootless-podman-が-outer-runtime-に止められている) |
| `podman system migrate` の自己修復ログ | [§5](#5-stale-state-は-podman-system-migrate-で直る) |
| `cgroup.subtree_control` で止まる | [§6](#6-rootful-service-build-が-cgroup-で止まる) |
| interactive SSH が Copilot session へ入らない | [§7](#7-interactive-ssh-が-copilot-session-へ入らない) |
| private image pull が unauthorized | [§8](#8-private-image-を-pull-できない) |
| Service の `EXTERNAL-IP` が `pending` | [§9](#9-service-の-external-ip-が未割当て) |
| injected Copilot config が壊れている | [§10](#10-injected-copilot-config-が壊れている) |
| gh Secret の指定が足りない | [§11](#11-gh-secret-の指定が足りない) |
| execution image の bootstrap に失敗する | [§12](#12-execution-image-の-bootstrap-に失敗する) |

## 1. bundled skill が読めない

### 代表ログ

```text
cat: /home/copilot/.copilot/skills/repo-change-delivery/SKILL.md: Permission denied
```

### 意味

bundled skill directory の mode が壊れ、path traversal ができません。copy 同期後の
directory / file mode が崩れると発生します。

### 期待する確認結果

- `~/.copilot/skills/repo-change-delivery` が symlink ではない
- skill directory が `drwxr-xr-x` 相当
- `SKILL.md` が `-rw-r--r--` 相当

## 2. capability が足りず起動時に止まる

### 代表ログ

```text
Missing Linux capabilities for control-plane startup: CHOWN DAC_OVERRIDE FOWNER SETGID SETUID SYS_CHROOT
```

### 意味

`drop: ALL` は有効でも、SSH と entrypoint の初期化に必要な capability が
戻っていません。最低でも
`AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER SETGID SETUID SYS_CHROOT` が必要です。
`CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service` のときは、
`KILL MKNOD NET_ADMIN SETFCAP SETPCAP SYS_ADMIN` も追加で必要です。

## 3. interactive SSH で切れる / `sshd` cleanup 警告が出る

### 代表ログ

```text
cleanup_exit: kill(...): Operation not permitted
```

### 意味

preauth cleanup か privilege separation / PTY login accounting 周辺で capability が
不足しています。`drop: ALL` でも戻すべき capability があります。
少なくとも `AUDIT_WRITE` と `KILL` が必要です。`SETUID`、`SETGID`、
`SYS_CHROOT` も戻してください。

### 回帰テストの目印

```text
job-check: ssh-clean=ok
job-check: ssh-interactive=ok
```

`scripts/test-ssh-session-persistence.sh` は SSH 接続をしばらく保持したまま動きます。
接続後に追加の入力を流して marker file を更新します。
`job-check: ssh-interactive=ok` は「session が見えた」だけではありません。
SSH login が十分に維持されて、post-login input も処理できたことを意味します。

## 4. rootless Podman が outer runtime に止められている

### 代表ログ

```text
cannot clone: Operation not permitted
invalid internal status, try resetting the pause process with "/usr/bin/podman system migrate": cannot re-exec process
cannot set user namespace
newuidmap: write to uid_map failed: Operation not permitted
```

### 意味

Pod 内設定ではなく、outer runtime / CRI / host 側が nested user namespace を
許していません。rootless へ固執せず、Kubernetes Job または
rootful-service fallback を優先してください。

## 5. stale state は `podman system migrate` で直る

### 代表ログ

```text
legacy local runtime wrapper: detected stale rootless Podman state; attempting `podman system migrate` once.
legacy local runtime wrapper: `podman system migrate` repaired the local Podman state.
```

### 意味

壊れているのが host 制約ではなく pause process / netns などの stale state なら、wrapper が 1 回だけ自己修復を試みています。

## 6. rootful-service build が cgroup で止まる

### 代表ログ

```text
opening file `/sys/fs/cgroup/cgroup.subtree_control` for writing: Read-only file system
```

### 意味

current-cluster の rootful-service build は、既定 isolation のままだと詰まります。
`CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot` か
`BUILDAH_ISOLATION=chroot` が必要です。

### 期待する確認結果

```text
job-check: podman-build=ok
current-cluster-test: podman-build=ok
```

## 7. interactive SSH が Copilot session へ入らない

### 代表ログ

```text
mode=login action=bash-il
```

### 意味

`CONTROL_PLANE_SSH_SHELL_LOG` にこの行が出るのは、interactive SSH login が
Copilot 用 Screen session へ入らず通常の login shell へ落ちたことを示します。
典型例は TTY が無い、`control-plane-session` が見つからない、あるいは login
shell を command mode (`ssh host '...'`) で使っている場合です。

## 8. private image を pull できない

### 代表ログ

```text
unable to retrieve auth token: invalid username/password: unauthorized: authentication required
```

### 意味

Kubernetes 側の image pull 認証が足りていません。
次のような Job / exec 用 image に private registry を使う場合があります。

- `CONTROL_PLANE_FAST_EXECUTION_IMAGE`
- `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE`
- `CONTROL_PLANE_BIOME_HOOK_IMAGE`

そのときは Deployment / ServiceAccount に `imagePullSecrets` を
付けてください。
fast exec を dedicated な `control-plane-exec` ServiceAccount で動かすなら、
その ServiceAccount 側にも同じ pull secret が必要です。
Control Plane の runtime file や `/run/control-plane-auth` の Secret mount では
代替しません。

## 9. Service の `EXTERNAL-IP` が未割当て

### 代表状態

```text
kubectl get svc -n copilot-sandbox
```

で `EXTERNAL-IP` が `pending` のまま。

### 意味

LoadBalancer の割り当て待ちです。
SSH 自体の検証は
`kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
で先に進められます。

## 10. injected Copilot config が壊れている

### 代表ログ

```text
Expected injected Copilot config at /var/run/control-plane-config/copilot-config.json to contain a top-level JSON object
```

### 意味

`COPILOT_CONFIG_JSON_FILE` へ渡したファイルが JSON object ではないか、
JSON 自体が壊れています。entrypoint は PVC 上の既存
`~/.copilot/config.json` と deep-merge する前提です。
top-level array / string / invalid JSON は受け付けません。

## 11. gh Secret の指定が足りない

### 代表ログ

```text
Expected gh GitHub token source at /var/run/control-plane-auth/gh-github-token
Refusing to install an empty gh hosts source from /var/run/control-plane-auth/gh-hosts.yml
```

### 意味

`GH_GITHUB_TOKEN_FILE` または `GH_HOSTS_YML_FILE` を env で指定したのに、
対応する Secret key が無いか空です。`gh-hosts.yml` を使う場合は、その file が
優先されます。無ければ `gh-github-token` から最小
`~/.config/gh/hosts.yml` を生成する順序で動きます。

## 12. execution image の bootstrap に失敗する

### 代表ログ

```text
unsupported execution image package manager: need apk or apt-get
```

### 意味

Execution Pod の base image が `/bin/sh` を持たないか、bootstrap 時に `apk` / `apt-get`
のどちらも使えません。現行の session-exec bootstrap は、まず staged Rust gRPC binary
を起動し、その後 gRPC 経由で `bash` / `git` / `gh` / `kubectl` / `openssh-client`
を導入する前提です。

### 期待する確認結果

- `CONTROL_PLANE_FAST_EXECUTION_IMAGE` が Linux base image を指す
- image 内に `/bin/sh` がある
- image 内で `apk` か `apt-get` のどちらかが使える
