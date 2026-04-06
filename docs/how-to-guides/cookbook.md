# Cookbook

このページは、目的別に「何をすればよいか」だけを並べる How-to guide 集です。
どこから読むべきか迷ったら `docs/README.md`、背景説明は
`docs/explanation/knowledge.md`、runtime / path の事実関係は
`docs/reference/control-plane-runtime.md`、代表ログは
`docs/reference/debug-log.md` を参照してください。

## 1. 標準の lint / build / test を回す

```bash
./scripts/lint.sh
./scripts/build-test.sh
```

toolchain を固定したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
```

### current-cluster で詰まりやすい点

- `lint.sh` は bundled control-plane image を使って `yamllint` を実行する
- `control-plane-run` は Kubernetes Job 専用で、Copilot CLI の `bash` tool delegation とは別経路
- `hadolint` と `shellcheck` は fully-qualified image 名で pull する

runtime / cache / hook の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

## 2. current-cluster の smoke を取る

最小 smoke:

```bash
./scripts/test-k8s-job.sh
```

今いる Control Plane Pod 自体を spot check したい場合:

```bash
./scripts/test-current-cluster-regressions.sh
```

この 2 本で、少なくとも次を確認できます。

- bundled skill の `references/` が読める
- `COPILOT_CONFIG_JSON_FILE` と `GH_HOSTS_YML_FILE` / `GH_GITHUB_TOKEN_FILE` による設定注入が効く
- `drop: ALL` 系 capability 構成で interactive SSH login が接続維持後も入力を受け付ける
- bundled toolchain と runtime.env が期待どおり生成される
- `--mount-file` が SSH/SFTP + `rclone` で大きめのファイルも運べ、競合時は安全に write-back を止める
- `CONTROL_PLANE_FAST_EXECUTION_ENABLED=1` のとき、Copilot CLI の `bash`
  tool が session-scoped Execution Pod に委譲され、`sessionEnd` /
  OwnerReference で cleanup される

ConfigMap / Secret / write-back の具体的な path は
`docs/reference/control-plane-runtime.md` を参照してください。

## 3. sample manifest を current-cluster 向けに更新する

### image と tag を決める

1. `deploy/kubernetes/control-plane.example/` 配下には
   `replace-me-with-commit-sha` の placeholder が残っているので、
   使いたい published commit SHA tag にそろえて更新する
2. 再現性を重視するなら `latest` ではなく commit SHA tag を使う
3. `CONTROL_PLANE_JOB_TRANSFER_IMAGE` と `garage-bootstrap` Job の image も
   Control Plane image と同じ published tag に合わせる

### Secret と ConfigMap をそろえる

1. `control-plane-auth` Secret の `ssh-public-key` を自分の公開鍵へ
   差し替える
2. `gh` 認証は Secret 側で管理し、簡単な GitHub.com 用なら
   `gh-github-token`、複数 host や `git_protocol: ssh` を含めたいなら
   `gh-hosts.yml` を使う。どちらも startup 時に `gh` 用の managed config へ
   取り込まれ、`/run/control-plane-auth` の raw mount を直接読む運用はしない
3. 必要なら `dockerhub-username` / `dockerhub-token` と
   `copilot-github-token` も入れる。DockerHub Secret は Control Plane
   起動時に Podman auth へ取り込み、Copilot token も private runtime file へ
   staging される。いずれも `/run/control-plane-auth` から直接読まない
4. Copilot CLI の追加設定は `control-plane-config` ConfigMap の
   `copilot-config.json` へ書き、PVC 上の既存 `~/.copilot/config.json`
   へ merge させる
5. namespace / PVC / Job 既定値や file path などの非機密 env は
   `control-plane-env` ConfigMap にまとめ、Deployment の `envFrom` で読む
6. Copilot CLI の `bash` tool を fast execution pod へ委譲する場合は、
   `CONTROL_PLANE_FAST_EXECUTION_*` と
   `CONTROL_PLANE_COPILOT_SESSION_{PVC,GH_SUBPATH,SSH_SUBPATH}` も
   `control-plane-env` に置く
7. `CONTROL_PLANE_POD_NAME` / `CONTROL_PLANE_POD_NAMESPACE` /
   `CONTROL_PLANE_POD_UID` / `CONTROL_PLANE_NODE_NAME` は Deployment の
   downward API `env:` で注入し、Execution Pod の OwnerReference / node pin
   に使う
8. control-plane ServiceAccount には同じ namespace の Pod を
   `create/delete/get/list/watch` できる Role / RoleBinding
   (`control-plane-exec-pods`) を付ける
9. `CONTROL_PLANE_FAST_EXECUTION_IMAGE` には delegated bash を実行したい
   任意の Linux image（例: `ubuntu:24.04` や `alpine:3.22`）を置き、
   `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` には Rust 製 exec-plane
   binary と bundled Git hook を持つ control-plane image を置く
10. 監査ログ DB の保持件数は `control-plane-env` ConfigMap の
   `CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）で調整する

### 永続化と storage class を合わせる

1. 永続化は、初回導入時だけ `deploy/kubernetes/control-plane.example/install/`
   で apply する `copilot-sandbox` Namespace、RWX の copilot session PVC、RWO の
   `sccache` object-store PVC、
   そして通常 sample 側に含まれる RWO の `/workspace` PVC を基本にする
2. `~/.copilot/tmp` と Podman cache は emptyDir の ephemeral storage に
   逃がし、再生成可能な container cache が session PVC を食い潰さない
   ようにする
3. shared PVC の spec は bound 後に自由に変更できないため、
   `control-plane.example/install/pvc-control-plane-copilot-session.yaml` と
   `control-plane.example/install/pvc-control-plane-sccache.yaml` は
   初回導入前に storage class / サイズを実クラスタ向けへ確定させる。
   `control-plane-copilot-session-pvc` は RWX を想定しているので、
   `replace-me-with-rwx-storage-class` を実クラスタ向けに置き換える
4. `control-plane-workspace-pvc` も PVC spec なので、`base/` や
   `overlays/default/` で storage class / サイズを変えるなら、
   初回導入前に反映しておく
5. `control-plane-sccache-pvc` は standalone Garage Deployment 専用の
   `ReadWriteOnce` claim です。Garage 本体は公式 `dxflrs/garage:v2.2.0`
   image で動かし、initContainer が `garage.toml` を生成します。bucket /
   quota / lifecycle の初期化は、別 Pod で 1 回だけ走る `garage-bootstrap`
   Job に分離し、その処理本体は既存の `control-plane` image に同梱した
   bootstrap script を使います。`garage-bootstrap` は Garage admin API の
   `CreateKey` で `sccache` 用 key を生成または再利用し、`garage-sccache-auth`
   Secret を必要なら新規作成しつつ反映します
6. `GARAGE_CACHE_QUOTA_BYTES=4294967296` を維持し、5Gi の dedicated PVC に
   対して 20% の headroom を残す。古い cache object は
   `GARAGE_CACHE_EXPIRATION_DAYS` の lifecycle で自動削除する
7. `SCCACHE_ENDPOINT` は
   `http://garage-s3.<namespace>.svc.cluster.local:3900` を指し、
   Rust Job は PVC を mount せず Service 経由で接続する。Garage 自身の
   `rpc_public_addr` は initContainer が Pod IP から組み立てる
8. Rust Job の S3 credential は `garage-sccache-auth` Secret を control-plane Pod に
   mount し、`k8s-rust.sh` が job-local `SCCACHE_CONF` へ埋め込む。sample では
   この Secret を manifest に含めず、`garage-bootstrap` Job が生成した Garage key
   で作成・更新する。Rust Job の `cargo` / `rustup` / `target` / `sccache`
   client state は `/var/tmp/containerized-rust/...` に寄せ、shared `/workspace`
   PVC に Rust cache を残さない

永続 path、Podman graphroot、ConfigMap / Secret の注入先などの具体的な
path は `docs/reference/control-plane-runtime.md` を参照してください。

反映:

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
kubectl get job garage-bootstrap -n copilot-sandbox
```

通常更新では共有 PVC を含まない次のパスを使います。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

`garage-bootstrap` Job は Garage Pod の通常再起動では rerun しません。fresh PVC
や bootstrap-managed Garage credential の再初期化が必要になったときだけ、
`kubectl delete job garage-bootstrap -n copilot-sandbox` のあとに shared PVC 定義と
通常 sample を順に再適用してください。

## 4. 今動いている Pod の image tag を確認する

current namespace の Pod を見る:

```bash
kubectl get pod "$(hostname)" -n "$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" \
  -o jsonpath='{.spec.containers[?(@.name=="control-plane")].image}{"\n"}'
```

外から確認する場合:

```bash
kubectl get pods -n copilot-sandbox -o wide
kubectl get pod <pod-name> -n copilot-sandbox -o jsonpath='{.spec.containers[*].image}{"\n"}'
```

## 5. `control-plane-run` の経路を選ぶ

`control-plane-run` は Kubernetes Job 専用です。Copilot CLI 自身の `bash`
tool は別経路で、bundled `preToolUse` hook が session-scoped Execution Pod
へ自動委譲します。`control-plane-run` は operator が explicit に叩く短命
command の Job 経路です。

基本形:

```bash
control-plane-run --mode k8s-job ...
```

## 6. SSH login を検証する

Service の `EXTERNAL-IP` がまだ無い場合は port-forward を使います。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
```

その後に SSH:

```bash
ssh -p 2222 copilot@127.0.0.1
```

session picker を一時的に避けたい場合だけ、Pod の env に `CONTROL_PLANE_DISABLE_SESSION_PICKER=1` を設定します。常用する既定値ではありません。

## 7. 典型的なデバッグの入口

- `ls: cannot access ... Permission denied`: bundled skill の同期結果と directory execute bit を確認する
- `cannot clone: Operation not permitted`: rootless 前提の説明を見直し、Execution Pod / Job 経路へ寄せる
- `cgroup.subtree_control: Read-only file system`: nested container 実行を前提にせず Job 経路を優先する
- `cleanup_exit: kill(`: SSH capability 構成を見直す

失敗ログの意味は `docs/reference/debug-log.md` を参照してください。
