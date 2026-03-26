# Debug log reference

このページは、current-cluster と Control Plane 周辺で実際に重要になる
ログ断片を引くための Reference です。手順は
`docs/how-to-guides/cookbook.md`、背景説明は
`docs/explanation/knowledge.md`、runtime / path の事実関係は
`docs/reference/control-plane-runtime.md` を参照してください。

このリポジトリの rootful-service sample では、local Podman の graphroot を既定で `/var/lib/control-plane/rootful-podman/rootful-overlay/storage` に置き、runtime dir は `/var/tmp/control-plane/rootful-overlay` へ寄せます。graphroot の背後は disposable な `emptyDir` cache、runtime dir も disk-backed `emptyDir` を想定し、Pod 再作成時に再生成できる local image store を persistent volume から切り離しています。

## Quick index by symptom

| Symptom | Section |
| --- | --- |
| `Permission denied` で bundled skill が読めない | [§1](#1-bundled-skill-が読めない) |
| capability 不足で起動時に止まる | [§2](#2-capability-が足りず起動時に止まる) |
| SSH が切れる / `cleanup_exit` が出る | [§3](#3-interactive-ssh-で切れる--sshd-cleanup-警告が出る) |
| rootless Podman の user namespace error | [§4](#4-rootless-podman-が-outer-runtime-に止められている) |
| `podman system migrate` の自己修復ログ | [§5](#5-stale-state-は-podman-system-migrate-で直る) |
| `cgroup.subtree_control` で止まる | [§6](#6-rootful-service-build-が-cgroup-で止まる) |
| session picker が使えず shell へ落ちる | [§7](#7-session-picker-が使えず-shell-へ落ちる) |
| DHI base image pull が unauthorized | [§8](#8-dhi-base-image-を-pull-できない) |
| Service の `EXTERNAL-IP` が `pending` | [§9](#9-service-の-external-ip-が未割当て) |
| injected Copilot config が壊れている | [§10](#10-injected-copilot-config-が壊れている) |
| gh Secret の指定が足りない | [§11](#11-gh-secret-の指定が足りない) |
| 監査分析 hook の設定が壊れている | [§12](#12-監査分析-hook-の設定が壊れている) |
| `control-plane-sccache-pvc` が `Pending` のまま | [§13](#13-garage-cache-pvc-が-bound-しない) |

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

## 10. injected Copilot config が壊れている

### 代表ログ

```text
Expected injected Copilot config at /var/run/control-plane-config/copilot-config.json to contain a top-level JSON object
```

### 意味

`COPILOT_CONFIG_JSON_FILE` へ渡したファイルが JSON object ではないか、JSON 自体が壊れています。entrypoint は PVC 上の既存 `~/.copilot/config.json` と deep-merge する前提なので、top-level array / string / invalid JSON は受け付けません。

## 11. gh Secret の指定が足りない

### 代表ログ

```text
Expected gh GitHub token source at /var/run/control-plane-auth/gh-github-token
Refusing to install an empty gh hosts source from /var/run/control-plane-auth/gh-hosts.yml
```

### 意味

`GH_GITHUB_TOKEN_FILE` または `GH_HOSTS_YML_FILE` を env で指定したのに、対応する Secret key が無いか空です。`gh-hosts.yml` を使う場合はその file が優先され、無ければ `gh-github-token` から最小 `~/.config/gh/hosts.yml` を生成する、という順序で動きます。

## 12. 監査分析 hook の設定が壊れている

### 代表ログ

```text
control-plane audit analysis: Audit analysis config at /home/copilot/.copilot/config.json must define controlPlane.auditAnalysis as a JSON object.
```

### 意味

`control-plane-config` ConfigMap の `copilot-config.json` overlay で、`controlPlane.auditAnalysis` が JSON object ではないか、壊れた値が入っています。bundled `audit-log-analysis` skill と lifecycle analysis hooks (`agentStop` / `subagentStop` / `sessionEnd` / `errorOccurred`) は同じ設定を読むため、ここが壊れると `~/.copilot/session-state/audit/audit-analysis.db` の更新も止まります。

### 期待する確認結果

- `~/.copilot/config.json` の `controlPlane.auditAnalysis` が JSON object
- `~/.copilot/session-state/audit/audit-analysis.db` が存在する
- `node ~/.copilot/skills/audit-log-analysis/scripts/audit-analysis.mjs status --json` が成功する

## 13. Garage cache PVC が Bound しない

### 代表ログ

```text
Warning  FailedScheduling  default-scheduler  0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims.
```

### 意味

sample manifest の `control-plane-sccache-pvc` は standalone Garage
Deployment 専用の `ReadWriteOnce` claim です。Job 側へ PVC を mount するのではなく、
`garage-s3` Service 経由で各クライアントを接続させる前提なので、この claim が
Bound しないと Garage Pod が立ち上がりません。

### 期待する確認結果

- `kubectl get pvc control-plane-sccache-pvc -n copilot-sandbox` が `Bound`
- `kubectl get pod -n copilot-sandbox -l app.kubernetes.io/name=garage-s3` が `1/1 Ready`
- `kubectl get svc garage-s3 -n copilot-sandbox` で `3900/TCP` が見える
- `kubectl get job garage-bootstrap -n copilot-sandbox` が `Complete`

`garage-bootstrap` Job が失敗した場合は、まず
`kubectl logs -n copilot-sandbox job/garage-bootstrap` で bootstrap の失敗点を見ます。
fresh PVC や bootstrap-managed Garage credential を再初期化したいときだけ、`kubectl delete job garage-bootstrap -n copilot-sandbox`
のあとに sample manifest を再適用して rerun してください。bootstrap 処理は
`control-plane` image に同梱した script が実行します。
