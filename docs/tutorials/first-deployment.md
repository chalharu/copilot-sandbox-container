# はじめての control plane 導入

この tutorial では、sample manifest を自分のクラスタ向けに調整し、
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:<tag>` を deploy して、
ACP を話す control-plane Pod と、Axum backend + Leptos CSR frontend を持つ
web Pod を立ち上げます。最後に web health / UI / service 到達性まで確認します。

この手順は単一 instance を sample manifest（Kustomize）で入れる経路です。複数 repo
や複数 instance を同じ cluster へ並べたい場合は、
`deploy/helm/control-plane/README.md` の Helm chart を使ってください。

## ゴール

この手順を終えると、少なくとも次を確認できます。

- `copilot-sandbox` namespace に `control-plane` と `control-plane-web` Pod が起動している
- shared session PVC と workspace PVC が `Bound` している
- `curl http://127.0.0.1:8080/healthz` で backend health を確認できる
- browser で `http://127.0.0.1:8080/` を開ける

## 事前に用意するもの

- `kubectl`
- deploy 先 cluster への `kubectl` 権限
- session 用の `ReadWriteMany` storage class
- workspace PVC 用の storage class（sample の既定は `standard`）
- Execution Pod が node ごとに使う environment PVC 用の storage class
  （`CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS`。sample の既定は
  `standard`）
- `latest` 以外へ pin したい場合だけ published control-plane image tag

## 1. sample manifest の置き場所を確認する

この tutorial で既定名のまま導入する場合に触るのは、次の 5 ファイルです。

- `deploy/kubernetes/control-plane.example/install/pvc-control-plane-copilot-session.yaml`
- `deploy/kubernetes/control-plane.example/base/pvc-control-plane-workspace.yaml`
- `deploy/kubernetes/control-plane.example/common/secret-control-plane-auth.yaml`
- `deploy/kubernetes/control-plane.example/common/configmap-control-plane-env.yaml`
- `deploy/kubernetes/control-plane.example/base/deployment-control-plane.yaml`

namespace や `Deployment` / `Service` / workspace PVC 名も変えたい場合だけ、
`deploy/kubernetes/control-plane.example/overlays/default/kustomization.yaml` を
複製した named overlay を追加で使います。default overlay が helper image や
job-transfer host の追従を持つため、従来より patch 箇所は少なくて済みます。

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

sample 既定の `ReadWriteOnce` 想定で十分なら、そのまま使えます。Execution Pod は
control-plane Pod と同じ node に pin されるため、同じ PVC を mount しても
矛盾しません。

## 4. 必要な認証情報を入れる

`common/secret-control-plane-auth.yaml` では、必要な認証情報だけを入れます。
典型的には `gh-github-token`、`gh-hosts.yml`、`copilot-github-token` を使います。

```yaml
stringData:
  gh-github-token: github_pat_... replace-me
```

GitHub Enterprise や複数 host を使う場合は `gh-hosts.yml` を、Copilot token を
起動時に注入したい場合は `copilot-github-token` を同じ Secret に追加します。

## 5. 環境変数と image をそろえる

`common/configmap-control-plane-env.yaml` では、shared 側の runtime 設定を
cluster に合わせます。まず確認するのは次です。

- `CONTROL_PLANE_FAST_EXECUTION_IMAGE`
- `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS`

`CONTROL_PLANE_FAST_EXECUTION_IMAGE` には、delegated `bash` を実行したい
runtime image を入れます。別の image に変える場合は、bootstrap が使えるように
`/bin/sh` と `apt-get` または `apk` を含む image を使ってください。shared
cluster では digest pin を推奨します。

`CONTROL_PLANE_K8S_NAMESPACE`、`CONTROL_PLANE_JOB_NAMESPACE`、
`CONTROL_PLANE_COPILOT_SESSION_PVC`、workspace PVC 名、job-transfer host、
helper image は shipped kustomization が自動で追従させます。namespace や
resource 名を変えるたびに ConfigMap を手で合わせ直す必要はありません。

`base/deployment-control-plane.yaml` または named overlay の `images:` で
control-plane image を決めます。sample の既定は
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest` です。
再現性を上げたい場合だけ GitHub Packages の `copilot-sandbox-container/control-plane`
（<https://github.com/chalharu/copilot-sandbox-container/pkgs/container/copilot-sandbox-container%2Fcontrol-plane>）
から full commit SHA tag を選んでここを pin します。sample 付属の
`control-plane-instance-env` ConfigMap には同じ tag が自動反映されるので、
`CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` と
`CONTROL_PLANE_JOB_TRANSFER_IMAGE` を別途合わせる必要はありません。

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
kubectl get svc -n copilot-sandbox
```

期待値:

- `control-plane-copilot-session-pvc` と `control-plane-workspace-pvc` が `Bound`
- `control-plane` と `control-plane-web` Pod が `Running`

ここで `Pending` や `ImagePullBackOff` が出る場合は、
`deploy/kubernetes/README.md` と `docs/reference/debug-log.md` を参照してください。

## 8. web backend / frontend へ到達する

Service の `EXTERNAL-IP` がまだ無い場合は `control-plane-web` を port-forward します。

```bash
kubectl port-forward service/control-plane-web 8080:8080 -n copilot-sandbox
```

port-forward を動かしたまま、別 terminal から health check を実行します。

```bash
curl http://127.0.0.1:8080/healthz
```

その後に browser で `http://127.0.0.1:8080/` を開きます。

## 9. ACP / web service を spot check する

内部 ACP service も確認したい場合は、別 terminal で次を実行します。

```bash
kubectl port-forward service/control-plane 3000:3000 -n copilot-sandbox
```

`control-plane` Service は cluster 内から backend が使う ACP endpoint です。
通常の利用者は `control-plane-web` 側だけ見れば十分です。

## 次に読む文書

- day 2 の運用手順: `docs/how-to-guides/cookbook.md`
- 複数 repo / instance を並べる Helm chart: `deploy/helm/control-plane/README.md`
- runtime / state / hook の正確な path: `docs/reference/control-plane-runtime.md`
- 代表的な失敗ログ: `docs/reference/debug-log.md`
- どの文書から読むか迷ったら: `docs/README.md`
