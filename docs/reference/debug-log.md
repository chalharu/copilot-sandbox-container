# Debug log reference

このページは、current-cluster と Control Plane 周辺で実際に重要になるログ断片を引くための Reference です。手順は `docs/how-to-guides/cookbook.md`、背景説明は `docs/explanation/knowledge.md` を参照してください。

current-cluster の rootful-service では、起動遅延を避けるため local Podman の graphroot を既定で `/run/control-plane/state-vfs/storage` のような ephemeral path に置きます。古い PVC 配下の `~/.copilot/containers/rootful-*` は起動 hot path から外れるため、残っていても次回 startup の主要因にならない想定です。

## 1. bundled skill が読めない

### 代表ログ

```text
ls: cannot access '/home/copilot/.copilot/skills/control-plane-operations/references/control-plane-run.md': Permission denied
ls: cannot access '/home/copilot/.copilot/skills/control-plane-operations/references/skills.md': Permission denied
```

### 意味

`references/` directory に execute bit が無く、path traversal が壊れています。symlink 同期と image build 時の mode 崩れが主因です。

### 期待する確認結果

- `~/.copilot/skills/control-plane-operations` が symlink ではない
- `references/` が `drwxr-xr-x` 相当
- `control-plane-run.md` と `skills.md` が `-rw-r--r--` 相当

## 2. capability が足りず起動時に止まる

### 代表ログ

```text
Missing Linux capabilities for control-plane startup: CHOWN DAC_OVERRIDE FOWNER SETGID SETUID SYS_CHROOT
```

### 意味

`drop: ALL` は有効でも、SSH と entrypoint の初期化に必要な capability が戻っていません。最低でも `AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER SETGID SETUID SYS_CHROOT` が必要で、`CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service` のときは追加で `KILL MKNOD NET_ADMIN SETFCAP SETPCAP SYS_ADMIN` も必要です。

## 3. interactive SSH で切れる / `sshd` cleanup 警告が出る

### 代表ログ

```text
cleanup_exit: kill(...): Operation not permitted
```

### 意味

preauth cleanup か privilege separation / PTY login accounting 周辺で capability が不足しています。`drop: ALL` でも `AUDIT_WRITE`, `KILL`, `SETUID`, `SETGID`, `SYS_CHROOT` などを戻す必要があります。

### 回帰テストの目印

```text
job-check: ssh-clean=ok
job-check: ssh-interactive=ok
```

`scripts/test-ssh-session-persistence.sh` は SSH 接続をしばらく保持したまま、接続後に追加の入力を流して marker file を更新します。`job-check: ssh-interactive=ok` は「session が見えた」だけでなく、SSH login が十分に維持されて post-login input も処理できたことを意味します。

## 4. rootless Podman が outer runtime に止められている

### 代表ログ

```text
cannot clone: Operation not permitted
invalid internal status, try resetting the pause process with "/usr/bin/podman system migrate": cannot re-exec process
cannot set user namespace
newuidmap: write to uid_map failed: Operation not permitted
```

### 意味

Pod 内設定ではなく outer runtime / CRI / host 側が nested user namespace を許していません。rootless へ固執せず、Kubernetes Job または rootful-service fallback を優先してください。

## 5. stale state は `podman system migrate` で直る

### 代表ログ

```text
control-plane-podman: detected stale rootless Podman state; attempting `podman system migrate` once.
control-plane-podman: `podman system migrate` repaired the local Podman state.
```

### 意味

壊れているのが host 制約ではなく pause process / netns などの stale state なら、wrapper が 1 回だけ自己修復を試みています。

## 6. rootful-service build が cgroup で止まる

### 代表ログ

```text
opening file `/sys/fs/cgroup/cgroup.subtree_control` for writing: Read-only file system
```

### 意味

current-cluster の rootful-service build は既定 isolation のままだと詰まります。`CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot` か `BUILDAH_ISOLATION=chroot` が必要です。

### 期待する確認結果

```text
job-check: podman-build=ok
current-cluster-test: podman-build=ok
```

## 7. session picker が使えず shell へ落ちる

### 代表ログ

```text
control-plane: session picker failed; continuing with the login shell. Set CONTROL_PLANE_DISABLE_SESSION_PICKER=1 to skip it entirely.
```

### 意味

picker 自体の失敗です。対話は継続できますが、Screen の自動再接続は効いていません。恒久回避は `CONTROL_PLANE_DISABLE_SESSION_PICKER=1` ですが、通常は原因を直すほうを優先します。

## 8. DHI base image を pull できない

### 代表ログ

```text
unable to retrieve auth token: invalid username/password: unauthorized: authentication required
```

### 意味

`dockerhub-username` / `dockerhub-token` Secret が無いか、`DOCKERHUB_USERNAME_FILE` / `DOCKERHUB_TOKEN_FILE` の引き回しができていません。`scripts/prepare-dhi-images.sh` と `scripts/validate-renovate-config.sh` は file path fallback を使える前提です。

## 9. Service の `EXTERNAL-IP` が未割当て

### 代表状態

```text
kubectl get svc -n copilot-sandbox
```

で `EXTERNAL-IP` が `pending` のまま。

### 意味

LoadBalancer の割り当て待ちです。SSH 自体の検証は `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox` で先に進められます。
