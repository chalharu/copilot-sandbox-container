# Cookbook

このページは、目的別に「何をすればよいか」だけを並べる How-to guide 集です。
どこから読むべきか迷ったら `docs/README.md` を参照してください。
背景説明は `docs/explanation/knowledge.md` を参照してください。
runtime / path の事実関係は `docs/reference/control-plane-runtime.md` を参照してください。
代表ログは `docs/reference/debug-log.md` を参照してください。

## 1. 標準の build / test を回す

```bash
./scripts/build-test.sh
```

toolchain を固定したい場合は次を実行します。

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
```

Docker daemon が使えず、current-cluster で build だけ確認したい場合は次を実行します。

```bash
./scripts/build-test.sh --build-only
CONTROL_PLANE_TOOLCHAIN=buildkitd ./scripts/build-test.sh --build-only
```

### current-cluster で詰まりやすい点

- PR lint は external `linter-service` が担当し、repo-managed な baseline は `build-test.sh` から始まる
- `--build-only` は Docker daemon が使えないとき、job namespace に Pod/Service を作れる current-cluster なら ephemeral Buildkitd に fallback できる
- `control-plane-run` は Kubernetes Job 専用で、Copilot CLI の `bash` tool delegation とは別経路
- focused rerun では `--build-only` と `--skip-image-build --group ...` を組み合わせると速い

runtime / cache / hook の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

## 2. current-cluster の smoke を取る

最小 smoke は次のとおりです。

```bash
./scripts/test-k8s-job.sh
```

今いる Control Plane Pod 自体を spot check したい場合は次を実行します。

```bash
./scripts/test-current-cluster-regressions.sh
```

この 2 本で、少なくとも次を確認できます。

- bundled skill の `references/` と bundled agent file が読める
- `COPILOT_CONFIG_JSON_FILE` と `GH_HOSTS_YML_FILE` / `GH_GITHUB_TOKEN_FILE` による設定注入が効く
- `drop: ALL` 系 capability 構成で interactive SSH login が接続維持後も入力を受け付ける
- bundled toolchain と runtime.env が期待どおり生成される
- `--mount-file` が SSH/SFTP + `rclone` で大きめのファイルも運べ、競合時は安全に write-back を止める
- `CONTROL_PLANE_FAST_EXECUTION_ENABLED=1` のとき、Copilot CLI の `bash`
  tool は session-scoped Execution Pod に委譲される
- Execution Pod は `sessionEnd` / OwnerReference で cleanup される

ConfigMap / Secret / write-back の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

## 3. sample manifest を current-cluster 向けに更新する

### image と tag を決める

1. sample manifest の既定値は
   `ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest`
   なので、そのまま初回導入に使える
2. 再現性を重視するなら GitHub Packages の
   `copilot-sandbox-container/control-plane`
   （<https://github.com/chalharu/copilot-sandbox-container/pkgs/container/copilot-sandbox-container%2Fcontrol-plane>）
   から full commit SHA tag を選び、`Deployment/control-plane` または named
   overlay の `images:` へ入れる。shipped replacement が
   `control-plane-instance-env` 側の
   `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` /
   `CONTROL_PLANE_JOB_TRANSFER_IMAGE` も同じ tag へそろえる
3. `CONTROL_PLANE_FAST_EXECUTION_IMAGE` の sample 既定は
   `docker.io/library/ubuntu:24.04`。別の image に変える場合は `/bin/sh` と
   `apt-get` または `apk` を含め、shared cluster では digest-pinned ref を使う

### Secret と ConfigMap をそろえる

1. `control-plane-auth` Secret の `ssh-public-key` を自分の公開鍵へ
   差し替える
2. `gh` 認証は Secret 側で管理し、簡単な GitHub.com 用なら
   `gh-github-token`、複数 host や `git_protocol: ssh` を含めたいなら
   `gh-hosts.yml` を使う。どちらも startup 時に `gh` 用の managed config へ
   取り込まれ、`/run/control-plane-auth` の raw mount を直接読む運用はしない
3. 必要なら `copilot-github-token` も入れる。Copilot token は private
   runtime file へ staging されるので、`/run/control-plane-auth` から直接
   読まない
4. Copilot CLI の追加設定は `control-plane-config` ConfigMap の
   `copilot-config.json` へ書き、PVC 上の既存 `~/.copilot/config.json`
   へ merge させる
5. 非機密 env は Deployment の `envFrom` で読み、shared な runtime 設定は
   `control-plane-env`、instance 固有の namespace / Service host / workspace PVC /
   helper image は `control-plane-instance-env` へ分ける
6. Copilot CLI の `bash` tool を fast execution pod へ委譲する場合は、
   shared な `CONTROL_PLANE_FAST_EXECUTION_*` と
   `CONTROL_PLANE_COPILOT_SESSION_{PVC,GH_SUBPATH,SSH_SUBPATH}` は
   `control-plane-env` に置き、helper image や job-transfer host は shipped
   replacement に追従させる
7. `CONTROL_PLANE_POD_NAME` / `CONTROL_PLANE_POD_NAMESPACE` /
   `CONTROL_PLANE_POD_UID` / `CONTROL_PLANE_NODE_NAME` は Deployment の
   downward API `env:` で注入し、Execution Pod の OwnerReference / node pin
   に使う
8. control-plane ServiceAccount には同じ namespace の Pod と ExecPod 用 PVC を
   `create/get/list/watch` でき、Pod は `delete` できる Role / RoleBinding
   (`control-plane-exec-pods`) を付ける。ただし shared namespace ではなく、
   control-plane 専用 namespace に閉じ込める
9. Exec Pod から in-cluster kubectl も使いたい場合は、
   `CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT` を dedicated な
   `control-plane-exec` ServiceAccount へ向け、`copilot-sandbox-jobs` 側では
   Deployment / Service / Job / Pod だけを許す
   `control-plane-exec-workloads` Role / RoleBinding を別で bind する。
   delegated shell の default namespace は control-plane 側のままなので、
   `kubectl -n "${CONTROL_PLANE_JOB_NAMESPACE}" ...` のように明示する
10. `CONTROL_PLANE_FAST_EXECUTION_IMAGE` には delegated bash を実行したい
    任意の Linux image（例: `ubuntu:24.04` や `alpine:3.22`）を置けるが、
    `/bin/sh` と `apt-get` または `apk` を必ず含め、本番では digest-pinned ref
    を使う。
    `CONTROL_PLANE_BIOME_HOOK_IMAGE` は bundled JS/TS Biome hook を別 Job image
    へ逃がす設定で、shipped sample 既定は Renovate-managed な official Biome
    image ref。
    `CONTROL_PLANE_RUST_HOOK_IMAGE` は compile-heavy な Rust hook を別
    toolchain image へ逃がす設定で、shipped sample 既定は Renovate-managed な
    official Rust image ref。
    `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` には Rust 製 exec-plane
    binary と bundled Git hook を持つ control-plane image を置く。sample
    既定では bootstrap 時に `bash` / `git` / `gh` / `kubectl` /
   `openssh-client` を chroot 内へ入れる。
   node-scoped cache は `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_PVC_PREFIX` /
   `..._STORAGE_CLASS` / `..._SIZE` / `..._MOUNT_PATH` で調整し、既定では
   `/environment/root` を chroot 先として使う。
   各 exec-pod 起動時に chroot 内で追加セットアップを走らせたい場合は
   `CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT` に inline shell snippet か
   script path を入れる。
   delegated command を非 root で走らせたい場合は
   `CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID` /
   `CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID` も合わせて定義する
11. 監査ログ DB の保持件数は `control-plane-env` ConfigMap の
    `CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）で調整する。

### 永続化と storage class を合わせる

1. 永続化の基本は次の 4 つである。
   - 初回導入時だけ `deploy/kubernetes/control-plane.example/install/` で apply する
     `copilot-sandbox` Namespace
   - RWX の copilot session PVC
   - 通常 sample 側に含まれる RWO の `/workspace` PVC
   - `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS` で作る node-local
     cache PVC
2. `~/.copilot/tmp` と Podman cache、fast-exec Execution Pod の `/tmp` と
   `/var/tmp` は generic ephemeral volume へ逃がし、再生成可能な cache が
   session PVC を食い潰さないようにする。
   `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS` と
   `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_SIZE` で storage class と合計サイズを
   調整する。storage class を省略する場合は cluster の default StorageClass を
   使う
3. shared PVC の spec は bound 後に自由に変更できないため、
   `control-plane.example/install/pvc-control-plane-copilot-session.yaml` は
   初回導入前に storage class / サイズを実クラスタ向けへ確定させる。
   `control-plane-copilot-session-pvc` は RWX を想定しているので、
   `replace-me-with-rwx-storage-class` を実クラスタ向けに置き換える
4. `control-plane-workspace-pvc` も PVC spec である。storage class / サイズを
   変えるなら初回導入前に反映しておく。named overlay で PVC 名まで変える場合も、
   shipped sample が mount 先と helper env を追従させる。PVC 側を 1 回 patch
   すれば十分である。sample 既定の `ReadWriteOnce` のままでも共有できる。
   Execution Pod は control-plane Pod と同じ node に pin されるためである。
   cluster に `standard` が無い場合は、workspace PVC 側だけでなく
   `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS` も同時に見直す。
5. Rust Job の `cargo` / `rustup` / `target` などの再生成可能な state は
   `/var/tmp/containerized-rust/...` に寄せ、shared `/workspace` PVC に cache を
   溜めない。fast-exec Execution Pod でも `/root/.cargo/config.toml` を自動生成し、
   `target-dir = "/var/tmp/control-plane/cargo-target"` に固定する

永続 path、Podman graphroot、ConfigMap / Secret の注入先などの具体的な
path は `docs/reference/control-plane-runtime.md` を参照してください。

反映には次を実行します。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

通常更新では共有 PVC を含まない次のパスを使います。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

## 4. 今動いている Pod の image tag を確認する

current namespace の Pod は次で確認します。

```bash
kubectl get pod "$(hostname)" -n "$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" \
  -o jsonpath='{.spec.containers[?(@.name=="control-plane")].image}{"\n"}'
```

外から確認する場合は次を実行します。

```bash
kubectl get pods -n copilot-sandbox -o wide
kubectl get pod <pod-name> -n copilot-sandbox -o jsonpath='{.spec.containers[*].image}{"\n"}'
```

## 5. `control-plane-run` の経路を選ぶ

`control-plane-run` は Kubernetes Job 専用です。Copilot CLI 自身の `bash`
tool は別経路で、bundled `preToolUse` hook が session-scoped Execution Pod
へ自動委譲します。`control-plane-session-exec proxy` はこの自動委譲の内部
helper です。operator や agent が `bash` tool から直接呼びません。
`control-plane-run` は operator が explicit に叩く短命 command の Job 経路です。

基本形は次のとおりです。

```bash
control-plane-run ...
```

## 6. SSH login を検証する

Service の `EXTERNAL-IP` がまだ無い場合は port-forward を使います。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
```

その後に SSH します。

```bash
ssh -p 2222 copilot@127.0.0.1
```

interactive SSH login は常に Copilot 用 GNU Screen session を再利用または作成します。
one-shot の shell command だけなら `ssh -p 2222 copilot@127.0.0.1 'bash -il'` のように
command mode を使います。

## 7. 典型的なデバッグの入口

- `ls: cannot access ... Permission denied`: bundled skill / agent の同期結果と directory execute bit を確認する
- `cannot clone: Operation not permitted`: rootless 前提の説明を見直し、Execution Pod / Job 経路へ寄せる
- `cgroup.subtree_control: Read-only file system`: nested container 実行を前提にせず Job 経路を優先する
- `cleanup_exit: kill(`: SSH capability 構成を見直す

失敗ログの意味は `docs/reference/debug-log.md` を参照してください。
