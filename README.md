# copilot-sandbox-container

このリポジトリの主役は
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:<tag>` です。
このイメージは、GitHub Copilot CLI を Kubernetes 上で動かすための
Control Plane を提供します。起動時に SSH login、Copilot / gh / SSH の永続 state、
`runtime.env`、bundled hook / skill、`control-plane-run` を整え、sample manifest
では Copilot CLI の `bash` tool を session-scoped Execution Pod へ自動委譲します。

## このコンテナイメージが行うこと

- SSH と GNU Screen を使う長寿命の control plane を起動する
- Copilot / GitHub / SSH の state を PVC に残し、Pod 再作成後も再開できるようにする
- Secret / ConfigMap から認証情報と設定を取り込み、`runtime.env` を生成する
- Copilot CLI の `bash` tool を session ごとの Execution Pod へ逃がす
- `control-plane-run` で明示的な command を Kubernetes Job として実行する

## このイメージが解決すること

- 長寿命の対話面と、build / test / lint などの実行面を分離できる
- `kubectl exec` に依存せず、SSH 再接続で Copilot session を継続できる
- 認証状態と session state を Pod ライフサイクルから切り離せる
- Control Plane Pod 内で nested runtime を抱えず、Execution Pod / Job 経路へ寄せられる

## Kubernetes クラスタへインストールする

### 1. 前提をそろえる

- `kubectl`, `ssh`, `ssh-keygen`, `ssh-keyscan`
- deploy 先 namespace と PVC を作成できる Kubernetes 権限
- session 用の `ReadWriteMany` storage class
- workspace 用の storage class（既定では `ReadWriteOnce` を想定）
- SSH 公開鍵
- 利用したい published image tag

### 2. sample manifest を書き換える

- `deploy/kubernetes/control-plane.example/install/pvc-control-plane-copilot-session.yaml`
- `deploy/kubernetes/control-plane.example/base/pvc-control-plane-workspace.yaml`
- `deploy/kubernetes/control-plane.example/common/secret-control-plane-auth.yaml`
- `deploy/kubernetes/control-plane.example/common/configmap-control-plane-env.yaml`
- `deploy/kubernetes/control-plane.example/base/deployment-control-plane.yaml`

書き換える値の詳細は `deploy/kubernetes/README.md` と
`docs/tutorials/first-deployment.md` を参照してください。

### 3. apply する

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

### 4. install 後に確認する

まずはローカル端末から Kubernetes 側の状態を確認します。

```bash
kubectl get pods -n copilot-sandbox
kubectl get pvc -n copilot-sandbox
```

port-forward は別 terminal で起動したままにしてください。

```bash
kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox
```

別 terminal から SSH:

```bash
ssh -p 2222 copilot@127.0.0.1
```

そのあと、このリポジトリを checkout しているローカル端末から次を実行します。

```bash
./scripts/test-k8s-job.sh
```

`./scripts/test-k8s-job.sh` は、このリポジトリの checkout と cluster への
`kubectl`/SSH 到達性を前提に、runtime / SSH / Job path をまとめて確認します。

## 関連ドキュメント

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
```

別 terminal から SSH:

```bash
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
