# Kubernetes サンプルマニフェスト

`deploy/kubernetes/control-plane.example/` は、control-plane の Kubernetes サンプルをまとめたエントリーポイントです。

初回導入や共有 PVC の作り直し時は、まず shared PVC 定義を適用し、そのあとで通常の kustomization を適用します。

```bash
kubectl apply -f deploy/kubernetes/control-plane.example/install/shared-persistent-volume-claims.yaml
kubectl apply -k deploy/kubernetes/control-plane.example
```

通常更新では、共有 PVC を含まないルート kustomization を使います。

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

## 構成

- `control-plane.example/common/`: Namespace、RBAC、Secret、ConfigMap、Garage S3 関連リソース、`garage-bootstrap` Job などの共通リソース。
- `control-plane.example/base/`: 1 つの control-plane インスタンスとして再利用する `PersistentVolumeClaim`、`Service`、`Deployment`。
- `control-plane.example/overlays/default/`: 同梱サンプルのカスタマイズ叩き台。`base/control-plane-instance.yaml` に対する書き換え候補をコメントで置いています。
- `control-plane.example/install/`: 初回導入時だけ apply する shared PVC 定義。shared PVC に加えて、先に必要になる `copilot-sandbox` Namespace も置いています。

ルートの `control-plane.example/kustomization.yaml` は、更新時に immutable な共有 PVC spec を触らないための通常運用パスです。`common/shared-resources.yaml` と `base/control-plane-instance.yaml` をそのまま読むことで、standalone `kustomize` と `kubectl kustomize` の両方で warning なく扱いやすい構成にしています。`control-plane-copilot-session-pvc` や `control-plane-sccache-pvc` のような bound 済み PVC は、storage class や access mode を再 apply で安全に変えられないため、初回導入用の `install/` へ分離しています。

## 最初に書き換える場所

1. `control-plane.example/install/shared-persistent-volume-claims.yaml` の shared PVC 設定をクラスタに合わせる。特に `control-plane-copilot-session-pvc` の RWX storage class は初回導入前に書き換える。
2. `control-plane.example/base/control-plane-instance.yaml` の workspace PVC 設定をクラスタに合わせる。PVC spec は bound 後に自由に変更できないので、storage class やサイズは初回導入前に確定させる。
3. `control-plane.example/common/shared-resources.yaml` の placeholder な credential とクラスタ依存値を置き換える。`garage-sccache-auth` は sample manifest では事前定義せず、`garage-bootstrap` Job が生成するので、通常は `control-plane-auth` と `garage-admin-auth` を主に調整する。
4. `control-plane` image tag を、次の 3 箇所でそろえて書き換える。
   - `control-plane.example/base/control-plane-instance.yaml` の `Deployment/control-plane`
   - `control-plane.example/common/shared-resources.yaml` の `ConfigMap/control-plane-env` にある `CONTROL_PLANE_JOB_TRANSFER_IMAGE`
   - `control-plane.example/common/shared-resources.yaml` の `Job/garage-bootstrap`
5. デフォルトのインスタンス名や workspace PVC 名を変えたい場合は、`control-plane.example/overlays/default/kustomization.yaml` の候補をベースに sibling overlay を作る。

## default overlay のカスタマイズ

`control-plane.example/overlays/default/kustomization.yaml` には、インスタンスごとに差し替えやすい項目の候補をコメントで入れています。これはそのまま root sample に読み込ませるのではなく、named variant を作るときの叩き台として使う想定です。

- workspace PVC 名
- デフォルトの `5Gi` では足りないときの workspace PVC サイズ
- workspace PVC の storage class
- 別の公開 revision に pin したいときの `control-plane` container image tag
- `Service` 名と selector label
- `Deployment` 名、selector label、pod template label、mount する workspace PVC 名

コメントは固有のサンプル名に寄せず、generic な形にしています。候補ブロックを uncomment して、`replace-me-*` を自分の値に置き換えて使ってください。

複数の名前付きインスタンスを同時に持ちたい場合は、`overlays/default/` を sibling overlay として複製し、同梱のルートとは別に compose 用の `kustomization.yaml` を追加してください。
