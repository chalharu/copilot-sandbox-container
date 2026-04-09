# はじめての control plane 導入

この tutorial では、sample manifest を自分のクラスタ向けに調整し、
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:<tag>` を deploy して
SSH で入れるところまでを通します。最後に `./scripts/test-k8s-job.sh` を使い、
Kubernetes Job 経路まで確認します。

## ゴール

この手順を終えると、少なくとも次を確認できます。

- `copilot-sandbox` namespace に control-plane Pod が起動している
- shared session PVC と workspace PVC が `Bound` している
- `ssh -p 2222 copilot@127.0.0.1` で login できる
- `./scripts/test-k8s-job.sh` で runtime / SSH / Job path の smoke を取れる

## 事前に用意するもの

- `kubectl`, `ssh`, `ssh-keygen`, `ssh-keyscan`
- deploy 先 cluster への `kubectl` 権限
- session 用の `ReadWriteMany` storage class
- workspace 用の storage class
- SSH 公開鍵
- 利用したい published control-plane image tag
- `./scripts/test-k8s-job.sh` を実行するなら、このリポジトリの local checkout

## 1. sample manifest の置き場所を確認する

この tutorial で触るのは次の 5 ファイルです。

- `deploy/kubernetes/control-plane.example/install/pvc-control-plane-copilot-session.yaml`
- `deploy/kubernetes/control-plane.example/base/pvc-control-plane-workspace.yaml`
- `deploy/kubernetes/control-plane.example/common/secret-control-plane-auth.yaml`
- `deploy/kubernetes/control-plane.example/common/configmap-control-plane-env.yaml`
- `deploy/kubernetes/control-plane.example/base/deployment-control-plane.yaml`

manifest 全体の役割を先に見たい場合は `deploy/kubernetes/README.md` を参照してください。

## 2. shared session PVC をクラスタ向けに合わせる

`install/pvc-control-plane-copilot-session.yaml` は、Copilot session の共有 state を
保持する PVC です。`ReadWriteMany` を満たす storage class に置き換えてください。

```yaml
storageClassName: replace-me-with-rwx-storage-class
```

この PVC は bound 後に spec を自由に変えにくいため、初回導入前に確定させます。

## 3. workspace PVC を決める

`base/pvc-control-plane-workspace.yaml` は、control plane と Execution Pod が共有する
`/workspace` 用 PVC です。必要に応じて storage class やサイズを変えます。

```yaml
storage: 5Gi
storageClassName: standard
```

既定の `ReadWriteOnce` 想定で十分なら、そのまま使えます。

## 4. SSH 公開鍵と必要な認証情報を入れる

`common/secret-control-plane-auth.yaml` では、最低限 `ssh-public-key` を
自分の公開鍵へ差し替えます。

```yaml
stringData:
  ssh-public-key: |
    ssh-ed25519 AAAA... your-key
```

`gh` CLI や Copilot token を最初から入れたい場合だけ、同じ Secret に
`gh-github-token`、`gh-hosts.yml`、`copilot-github-token` を追加します。

## 5. 環境変数と image をそろえる

`common/configmap-control-plane-env.yaml` では、少なくとも次を見直します。

- `CONTROL_PLANE_K8S_NAMESPACE`
- `CONTROL_PLANE_JOB_NAMESPACE`
- `CONTROL_PLANE_COPILOT_SESSION_PVC`
- `CONTROL_PLANE_WORKSPACE_PVC`
- `CONTROL_PLANE_FAST_EXECUTION_IMAGE`
- `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE`
- `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS`
- `CONTROL_PLANE_JOB_TRANSFER_IMAGE`

`CONTROL_PLANE_FAST_EXECUTION_IMAGE` には、delegated `bash` を実行したい
runtime image を入れます。shared cluster では digest pin を推奨します。

`base/deployment-control-plane.yaml` 側の `Deployment/control-plane` image も、
使いたい published revision に合わせて置き換えてください。

## 6. 初回導入を apply する

shared session PVC を含む初回導入では、`install/` を先に apply します。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

shared session PVC を作り直さない通常更新では、後者だけで十分です。

## 7. Pod と PVC を確認する

```bash
kubectl get pvc -n copilot-sandbox
kubectl get pods -n copilot-sandbox
```

期待値:

- `control-plane-copilot-session-pvc` と `control-plane-workspace-pvc` が `Bound`
- control-plane Pod が `Running`

ここで `Pending` や `ImagePullBackOff` が出る場合は、
`deploy/kubernetes/README.md` と `docs/reference/debug-log.md` を参照してください。

## 8. SSH で login する

Service の `EXTERNAL-IP` がまだ無い場合は port-forward を使います。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
```

port-forward を動かしたまま、別 terminal から SSH します。

```bash
ssh -p 2222 copilot@127.0.0.1
```

`Permission denied (publickey)` が出る場合は、
`common/secret-control-plane-auth.yaml` の `ssh-public-key` を見直してください。

## 9. Kubernetes Job 経路まで smoke を取る

このリポジトリを checkout している端末から、次を実行します。

```bash
./scripts/test-k8s-job.sh
```

この smoke では、runtime.env、bundled skill、SSH、`control-plane-run` 周辺の
基本経路をまとめて確認できます。

## 次に読む文書

- day 2 の運用手順: `docs/how-to-guides/cookbook.md`
- runtime / state / hook の正確な path: `docs/reference/control-plane-runtime.md`
- 代表的な失敗ログ: `docs/reference/debug-log.md`
- どの文書から読むか迷ったら: `docs/README.md`
