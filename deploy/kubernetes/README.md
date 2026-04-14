# Kubernetes サンプルマニフェスト

`deploy/kubernetes/control-plane.example/` は sample manifest です。
`ghcr.io/chalharu/copilot-sandbox-container/control-plane:<tag>` を Kubernetes へ
配置するために使います。はじめて導入する場合は
`docs/tutorials/first-deployment.md` を先に読んでください。このページは
「どのファイルをどう編集するか」を確認する reference として使います。

kustomize overlay を repo ごとに複製して追従する運用が重くなってきた場合は、
values から複数 instance を展開できる `deploy/helm/control-plane/` も使えます。

## どの kustomization を使うか

| 状況 | 実行するパス |
| --- | --- |
| 初回導入、または shared session PVC を作り直す | `deploy/kubernetes/control-plane.example/install` を apply してから、`deploy/kubernetes/control-plane.example` を apply |
| 通常更新 | `deploy/kubernetes/control-plane.example` のみ |

初回導入では次を実行します。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example/install
kubectl apply -k deploy/kubernetes/control-plane.example
```

通常更新では次を実行します。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

## 導入前に決めること

1. session 用 shared PVC に使う RWX storage class
2. workspace PVC の storage class とサイズ
3. Execution Pod が node ごとに使う environment PVC の storage class
   （`CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS`）
4. Execution Pod の `/tmp` と `/var/tmp` に使う generic ephemeral volume の設定
   - storage class: `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS`
   - 合計サイズ: `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_SIZE`
5. `control-plane-auth` Secret に入れる SSH 公開鍵
6. namespace や PVC 名を既定値のまま使うかどうか
7. `latest` のまま試すか、published image を full commit SHA tag へ pin するか

## 最初に書き換える場所

1. `control-plane.example/install/pvc-control-plane-copilot-session.yaml`
   - `replace-me-with-rwx-storage-class` を、`ReadWriteMany` を満たす
      storage class へ必ず置き換える
2. `control-plane.example/common/secret-control-plane-auth.yaml`
   - `ssh-public-key` を自分の公開鍵へ必ず差し替える
   - 必要なら `gh-github-token` / `gh-hosts.yml` /
     `copilot-github-token` を追加する
3. `control-plane.example/base/pvc-control-plane-workspace.yaml`
   - workspace PVC の storage class / サイズをクラスタに合わせる
   - sample 既定の `ReadWriteOnce` のままでも、Execution Pod が
      control-plane Pod と同じ node に pin されるため共有できる
4. `control-plane.example/common/configmap-control-plane-env.yaml`
   - cluster 固有の runtime 設定だけを調整する
   - `CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS` を、cluster に
     `standard` が無い場合は導入前に置き換える
   - `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS` を、dynamic
     provisioning 可能な storage class へ置き換える
   - `CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_SIZE` で `/tmp` と `/var/tmp` の
     合計上限を調整する
   - `CONTROL_PLANE_FAST_EXECUTION_IMAGE` を変える場合は `/bin/sh` と
     `apt-get` または `apk` を持つ image を使う
   - `CONTROL_PLANE_BIOME_HOOK_IMAGE` は bundled Biome hook を別 Job image
     へ逃がす。sample 既定は `ghcr.io/biomejs/biome:2.4.11`
   - namespace / session PVC / helper image の追従は shipped sample の
     replacements が持つので、名前変更のたびにここを書き換える必要はない
5. `control-plane.example/base/deployment-control-plane.yaml` または
    `control-plane.example/overlays/default/kustomization.yaml`
   - sample 既定は
     `ghcr.io/chalharu/copilot-sandbox-container/control-plane:latest`
   - image を差し替えると `control-plane/control-plane-instance-env` 側の
     `CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` /
     `CONTROL_PLANE_JOB_TRANSFER_IMAGE` も自動で追従する
   - 再現性が必要なら GitHub Packages の
     `copilot-sandbox-container/control-plane`
     （<https://github.com/chalharu/copilot-sandbox-container/pkgs/container/copilot-sandbox-container%2Fcontrol-plane>）
     から full commit SHA tag を選び、ここを pin する
6. `control-plane.example/overlays/default/kustomization.yaml`
   - namespace / Deployment / Service / workspace PVC 名を変える named overlay の
     叩き台として使う
   - この overlay には root sample と同じ alignment replacement が入っているので、
     コピーした先でも patch 後の namespace / Service / image 追従を維持できる

`control-plane.example/control-plane/configmap-control-plane-instance-env.yaml` は、
instance 固有値を持つ ConfigMap です。workspace PVC 名 / Service host / helper
image などを入れます。通常は直接編集せず、shipped replacement に追従させます。

## 構成

- `control-plane.example/shared-resources/`
  - Namespace、RBAC、Secret、shared ConfigMap をまとめた entry point
- `control-plane.example/control-plane/`
  - workspace PVC、Service、Deployment、instance 固有 env をまとめた
    control-plane entry point
- `control-plane.example/common/` / `control-plane.example/base/`
  - 上記 entry point から再利用する実体 manifest
- `control-plane.example/overlays/default/`
  - shipped root sample を包む最小 overlay。named variant の叩き台
- `control-plane.example/install/`
  - 初回導入時だけ apply する shared PVC と先行 namespace

ルートの `control-plane.example/kustomization.yaml` は
`shared-resources/` と `control-plane/` を compose します。namespace / Service
host / workspace PVC 名 / helper image の追従は、built-in replacement で
内包します。そのうえで、bound 済み shared PVC の spec を通常更新で触らないよう、
immutable な `control-plane-copilot-session-pvc` だけは `install/` に分離しています。

## 導入後に確認すること

- `kubectl get pvc -n copilot-sandbox` で session / workspace PVC が `Bound`
- `kubectl get pods -n copilot-sandbox` で control-plane Pod が `Running`
- `kubectl port-forward service/control-plane 2222:2222 -n copilot-sandbox`
  の後に `ssh -p 2222 copilot@127.0.0.1` でログインできる
- このリポジトリの checkout 上で `./scripts/test-k8s-job.sh` を実行できる

sample 既定では、delegated Execution Pod 用の `control-plane-exec`
ServiceAccount も含みます。`copilot-sandbox-jobs` 側の
`control-plane-exec-workloads` Role / RoleBinding も含みます。SSH shell や
delegated `bash` では `kubectl -n copilot-sandbox-jobs ...` を使えます。
作業後に削除する前提の Deployment / Service / Job / Pod を扱えます。

## default overlay のカスタマイズ

`control-plane.example/overlays/default/kustomization.yaml` は、root sample をそのまま
wrap するための named-variant 叩き台です。複数の名前付きインスタンスを同時に
持ちたい場合はこの directory を sibling overlay として複製し、そこへ必要な
patch だけを追加します。コピー後も replacement block は残してください。

通常は次だけで十分です。

- Namespace 名の差し替え
- `control-plane-auth` Secret や `control-plane-env` ConfigMap の内容差し替え
- workspace PVC の storage class / サイズ
- Deployment の resource / nodeSelector / imagePullPolicy
- `images:` による control-plane image tag の差し替え

workspace PVC mount 名、job-transfer host、bootstrap / transfer helper image は
shipped sample 側が自動で追従させます。Deployment と ConfigMap を二重に
編集する必要はありません。
