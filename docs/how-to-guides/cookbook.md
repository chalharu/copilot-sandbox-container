# Cookbook

このページは、目的別に「何をすればよいか」だけを並べる How-to guide 集です。背景説明は `docs/explanation/knowledge.md`、代表ログは `docs/reference/debug-log.md` に分離しています。

## 1. 標準の lint / build / test を回す

```bash
./scripts/lint.sh
./scripts/build-test.sh
```

toolchain を固定したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh
```

### current-cluster で詰まりやすい点

- Podman build は rootful-service で remote Podman socket と `--isolation=chroot` を既定に使う
- rootful-service image store は `/var/lib/control-plane/rootful-podman/rootful-overlay` の disposable emptyDir cache へ置き、runtime dir は `/var/tmp/control-plane/rootful-overlay` の disk-backed emptyDir へ逃がす
- `yamllint` image の DHI base image は `scripts/prepare-dhi-images.sh` で事前 pull する
- `hadolint` と `shellcheck` は fully-qualified image 名で pull する

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
- `COPILOT_CONFIG_JSON_FILE` と `GH_HOSTS_YML_FILE` / `GH_GITHUB_TOKEN_FILE` による設定注入が podman / Kubernetes の両方で効く
- `drop: ALL` 系 capability 構成で interactive SSH login が接続維持後も入力を受け付ける
- rootful-service の Podman graphroot が `~/.copilot/containers` ではなく disposable cache volume を使い、runtime dir は `/run` ではなく `/var/tmp/control-plane` 側へ逃がされる
- rootful-service 下の `podman build` と `podman run` が通る
- `--mount-file` が SSH/SFTP + `rclone` で大きめのファイルも運べ、競合時は安全に write-back を止める

## 3. sample manifest を current-cluster 向けに更新する

1. `deploy/kubernetes/control-plane.example.yaml` の `image` は `replace-me-with-commit-sha` の placeholder なので、使いたい published commit SHA tag に更新する
2. 再現性を重視するなら `latest` ではなく commit SHA tag を使う
3. `control-plane-auth` Secret の `ssh-public-key` を自分の公開鍵へ差し替える
4. `gh` 認証は Secret 側で管理し、簡単な GitHub.com 用なら `gh-github-token`、複数 host や `git_protocol: ssh` を含めたいなら `gh-hosts.yml` を使う
5. 永続化は RWX の copilot session PVC と RWO の `/workspace` PVC を基本にし、前者へ `~/.copilot/config.json`、`~/.copilot/session-state`、`~/.config/gh`、`~/.ssh`、SSH host key をまとめる。`~/.copilot/tmp` と `/var/lib/control-plane/rootful-podman` は emptyDir の ephemeral storage に置き、sample manifest の rootful-service は `overlay` を既定にする
6. Copilot CLI の追加設定は `control-plane-config` ConfigMap の `copilot-config.json` へ書き、PVC 上の既存 `~/.copilot/config.json` へ merge させる
7. 必要なら `dockerhub-username` / `dockerhub-token` と `copilot-github-token` も入れる
8. `CONTROL_PLANE_JOB_TRANSFER_IMAGE` は Control Plane image と同じ published tag に合わせる
9. `storageClassName` と PVC サイズをクラスタに合わせる。`control-plane-copilot-session-pvc` は RWX を想定しているので、sample manifest の `replace-me-with-rwx-storage-class` を実クラスタ向けに置き換える

反映:

```bash
kubectl apply -f deploy/kubernetes/control-plane.example.yaml
```

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

短い処理を local Podman へ寄せる:

```bash
control-plane-run --mode auto --execution-hint short --workspace /workspace --image <image> -- <command>
```

長い処理を Kubernetes Job へ寄せる:

```bash
control-plane-run --mode auto --execution-hint long --namespace copilot-sandbox-jobs --job-name <name> --image <image> -- <command>
```

経路を固定したい場合:

```bash
control-plane-run --mode podman ...
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
- `cannot clone: Operation not permitted`: rootless 前提の説明を見直し、Job 経路へ寄せる
- `cgroup.subtree_control: Read-only file system`: rootful-service build では `chroot` isolation を使う
- `cleanup_exit: kill(`: SSH capability 構成を見直す

失敗ログの意味は `docs/reference/debug-log.md` を参照してください。
