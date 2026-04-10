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

## runtime env の設定先

Git の `user.name` / `user.email`、`TZ`、Execution Pod の startup script は、
どれも各 instance の `control-plane-env` ConfigMap に入る値です。Helm では
次の 2 箇所から設定します。

| 用途 | values のキー | 反映先 |
| --- | --- | --- |
| 全 instance 共通の既定値 | `global.controlPlaneEnv` | すべての `control-plane-env` ConfigMap |
| repo ごとの上書き | `instances[].controlPlaneEnv` | 対象 instance の `control-plane-env` ConfigMap |

`instances[].instanceEnv` は workspace PVC 名や job-transfer host のような
chart 側の派生値向けなので、これらの設定先には使いません。

```yaml
global:
  controlPlaneEnv:
    CONTROL_PLANE_GIT_USER_NAME: Copilot Workspace Bot
    CONTROL_PLANE_GIT_USER_EMAIL: copilot@example.com
    TZ: Asia/Tokyo
    CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT: apt-get update && apt-get install -y ripgrep

instances:
  - name: repo-a
    auth:
      sshPublicKey: |
        ssh-ed25519 AAAA... repo-a

  - name: repo-b
    auth:
      sshPublicKey: |
        ssh-ed25519 AAAA... repo-b
    controlPlaneEnv:
      TZ: Europe/Berlin
      CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT: /workspace/scripts/bootstrap-exec.sh
```

- `CONTROL_PLANE_GIT_USER_NAME` / `CONTROL_PLANE_GIT_USER_EMAIL` は startup 時に
  managed global Git config へ書かれます。
- `TZ` は login shell と job tooling に渡されます。
- `CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT` は各 Execution Pod の chroot 内で
  `/bin/sh -lc` として実行されます。inline shell snippet でも、そこで見える
  script path でも構いません。

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
