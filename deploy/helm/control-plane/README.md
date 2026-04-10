# Helm chart for multi-repository control planes

`deploy/helm/control-plane/` は、repo ごとに `copilot + workspace PVC + Service`
を複数並べたいケース向けの Helm chart です。

各 `instances[]` エントリは、既定で次を 1 セット生成します。

- main namespace
- jobs namespace
- ServiceAccount / RBAC
- `control-plane-env` / `control-plane-instance-env` / `control-plane-config`
- session PVC / workspace PVC
- `control-plane` Deployment
- `control-plane` Service

既定値は、現在の kustomize sample と同じ `copilot-sandbox` /
`copilot-sandbox-jobs` 相当になるように寄せています。複数 repo を持つ場合は
`instances[]` を増やしてください。

## 使い方

まず最低限、各 instance の SSH 公開鍵と session PVC の RWX storage class を
上書きします。

```yaml
global:
  session:
    storageClassName: nfs-rwx

instances:
  - name: repo-a
    auth:
      sshPublicKey: |
        ssh-ed25519 AAAA... repo-a

  - name: repo-b
    namespace: repo-b-main
    jobNamespace: repo-b-jobs
    auth:
      existingSecretName: repo-b-auth
    workspace:
      existingClaim: repo-b-workspace-pvc
```

```bash
helm upgrade --install control-plane deploy/helm/control-plane \
  -f my-values.yaml
```

`instance.name` から namespace を自動生成する場合、既定では
`<namespacePrefix>-<name>` と `<namespace>-jobs` を使います。

## 主な override

- `instances[].image`: repo ごとの image tag / pullPolicy
- `instances[].service`: Service 名、type、port
- `instances[].workspace`: workspace PVC claim 名、size、storage class、subPath
- `instances[].session`: session PVC claim 名、size、storage class、GH / SSH subPath
- `instances[].auth.existingSecretName`: Secret を chart 外で管理したい場合
- `instances[].controlPlaneEnv`: runtime 用 ConfigMap の追加 override
- `instances[].instanceEnv`: kustomize replacement 相当の派生 env に対する追加 override

PVC は既定で `helm.sh/resource-policy: keep` を付け、chart uninstall で誤って
消えないようにしています。
