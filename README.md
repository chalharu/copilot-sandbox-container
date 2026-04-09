# copilot-sandbox-container

`copilot-sandbox-container` は、GitHub Copilot CLI を Kubernetes 上で使うための
Control Plane イメージ、sample manifest、検証スクリプトをまとめた
リポジトリです。SSH で入れる常駐の control plane、Copilot CLI の `bash`
tool を session 単位で実行する Execution Pod、明示的に叩く
`control-plane-run` の Kubernetes Job 経路を一緒に用意できます。

## このリポジトリが向いている人

- Copilot CLI の作業環境を Kubernetes 上へ置きたい
- `bash` tool の実行を session-scoped Execution Pod へ委譲したい
- 一回限りの処理を `control-plane-run` で Kubernetes Job として実行したい
- sample manifest と検証スクリプトを土台に、自分のクラスタへ導入したい

## はじめて使うときの最短ルート

### 1. 前提をそろえる

- `kubectl`, `ssh`, `ssh-keygen`, `ssh-keyscan`
- deploy 先 namespace と PVC を作成できる Kubernetes 権限
- session 用の `ReadWriteMany` storage class
- workspace 用の storage class（既定では `ReadWriteOnce` を想定）
- SSH 公開鍵
- 利用したい published image tag

### 2. tutorial を読む

`docs/tutorials/first-deployment.md`

### 3. sample manifest の placeholder を置き換える

- `deploy/kubernetes/control-plane.example/install/pvc-control-plane-copilot-session.yaml`
- `deploy/kubernetes/control-plane.example/base/pvc-control-plane-workspace.yaml`
- `deploy/kubernetes/control-plane.example/common/secret-control-plane-auth.yaml`
- `deploy/kubernetes/control-plane.example/common/configmap-control-plane-env.yaml`
- `deploy/kubernetes/control-plane.example/base/deployment-control-plane.yaml`

### 4. apply する

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

### 5. 動作確認する

```bash
kubectl get pods -n copilot-sandbox
kubectl get pvc -n copilot-sandbox
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
ssh -p 2222 copilot@127.0.0.1
./scripts/test-k8s-job.sh
```

`./scripts/test-k8s-job.sh` は、このリポジトリの checkout と cluster への
`kubectl`/SSH 到達性を前提に、runtime / SSH / Job path をまとめて確認します。

## 利用シーン別の入口

| やりたいこと | 読む文書 |
| --- | --- |
| 初回導入を最短で通したい | `docs/tutorials/first-deployment.md` |
| sample manifest の構成と編集ポイントを見たい | `deploy/kubernetes/README.md` |
| 既存環境の更新や smoke 手順を知りたい | `docs/how-to-guides/cookbook.md` |
| runtime.env、永続 state、hook / Git policy の path を引きたい | `docs/reference/control-plane-runtime.md` |
| 失敗ログから障害点を当たりたい | `docs/reference/debug-log.md` |
| なぜこの構成なのか知りたい | `docs/explanation/knowledge.md` |
| どの文書から読むか迷っている | `docs/README.md` |

## よく使う操作

### SSH で control plane に入る

Service の `EXTERNAL-IP` がまだ無い場合は port-forward を使います。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
ssh -p 2222 copilot@127.0.0.1
```

### `control-plane-run` で Kubernetes Job を実行する

```bash
control-plane-run \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/control-plane:replace-me-with-commit-sha \
  -- bash -lc 'printf "%s\n" job > /workspace/job.txt'
```

`control-plane-run` は明示的に叩く Job 経路です。Copilot CLI 自身の `bash`
tool は、bundled hook により別の session-scoped Execution Pod へ自動委譲されます。

### current-cluster の smoke を取る

```bash
./scripts/test-k8s-job.sh
```

すでに Control Plane Pod の中から spot check したい場合は
`./scripts/test-current-cluster-regressions.sh` も使えます。

## ドキュメント構成

- Tutorial: `docs/tutorials/first-deployment.md`
- How-to guides: `docs/how-to-guides/cookbook.md`
- Explanation: `docs/explanation/knowledge.md`, `docs/explanation/history.md`
- Reference: `docs/reference/control-plane-runtime.md`,
  `docs/reference/debug-log.md`

## リポジトリを改修したい場合

この README は利用者向けの入口です。リポジトリ自体を改修する場合は
`CONTRIBUTING.md` を参照し、repo-managed な baseline として次を使ってください。

```bash
./scripts/build-test.sh
```

Docker toolchain を固定したい場合:

```bash
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
```
