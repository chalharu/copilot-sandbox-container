# Kubernetes サンプルマニフェスト

`deploy/kubernetes/control-plane.example/` は、
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:<tag>` を Kubernetes へ
配置するための sample manifest です。はじめて導入する場合は
`docs/tutorials/first-deployment.md` を先に読み、このページは
「どのファイルをどう編集するか」を確認する reference として使ってください。

## どの kustomization を使うか

| 状況 | 実行するパス |
| --- | --- |
| 初回導入、または shared session PVC を作り直す | `deploy/kubernetes/control-plane.example/install` を apply してから、`deploy/kubernetes/control-plane.example` を apply |
| 通常更新 | `deploy/kubernetes/control-plane.example` のみ |

初回導入:

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

通常更新:

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

## 導入前に決めること

1. session 用 shared PVC に使う RWX storage class
2. workspace PVC の storage class とサイズ
3. `control-plane-auth` Secret に入れる SSH 公開鍵
4. `control-plane` image tag、fast execution 用 image ref、
   `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS`
5. namespace や PVC 名を既定値のまま使うかどうか

## 最初に書き換える場所

1. `control-plane.example/install/pvc-control-plane-copilot-session.yaml`
   - `ReadWriteMany` を満たす storage class へ置き換える
2. `control-plane.example/base/pvc-control-plane-workspace.yaml`
   - workspace PVC の storage class / サイズをクラスタに合わせる
3. `control-plane.example/common/secret-control-plane-auth.yaml`
   - `ssh-public-key` を自分の公開鍵へ差し替える
   - 必要なら `gh-github-token` / `gh-hosts.yml` /
     `copilot-github-token` を追加する
4. `control-plane.example/common/configmap-control-plane-env.yaml`
   - namespace、PVC 名、fast execution image、bootstrap image、
     job transfer image、exec-pod 用 environment PVC の storage class などを
     環境に合わせる
5. `control-plane.example/base/deployment-control-plane.yaml`
   - `Deployment/control-plane` の image tag を published revision に合わせる
6. `control-plane.example/overlays/default/kustomization.yaml`
   - 既定名以外で運用したい場合の叩き台として使う

## 構成

- `control-plane.example/common/`
  - Namespace、RBAC、Secret、ConfigMap などの共通リソース
- `control-plane.example/base/`
  - `PersistentVolumeClaim`、`Service`、`Deployment` など、1 つの
    control-plane インスタンスを構成する基本リソース
- `control-plane.example/overlays/default/`
  - 名前や PVC 名を変えるときのカスタマイズ叩き台
- `control-plane.example/install/`
  - 初回導入時だけ apply する shared PVC と先行 namespace

ルートの `control-plane.example/kustomization.yaml` は、bound 済み shared PVC の
spec を通常更新で触らないための運用パスです。immutable な
`control-plane-copilot-session-pvc` を通常の `kubectl apply -k` から切り離すため、
初回導入用の `install/` を分けています。

## 導入後に確認すること

- `kubectl get pvc -n copilot-sandbox` で session / workspace PVC が `Bound`
- `kubectl get pods -n copilot-sandbox` で control-plane Pod が `Running`
- `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
  の後に `ssh -p 2222 copilot@127.0.0.1` でログインできる
- このリポジトリの checkout 上で `./scripts/test-k8s-job.sh` を実行できる

## default overlay のカスタマイズ

`control-plane.example/overlays/default/kustomization.yaml` には、次の差し替え候補を
コメントで入れています。

- workspace PVC 名
- workspace PVC のサイズと storage class
- `control-plane` container image tag
- `Service` 名と selector label
- `Deployment` 名、selector label、pod template label、mount する workspace PVC 名

複数の名前付きインスタンスを同時に持ちたい場合は、`overlays/default/` を
sibling overlay として複製し、同梱のルートとは別に compose 用の
`kustomization.yaml` を追加してください。
