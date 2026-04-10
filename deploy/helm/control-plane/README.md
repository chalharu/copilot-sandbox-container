# Helm chart for multi-repository control planes

`deploy/helm/control-plane/` は、repo ごとに `copilot + workspace PVC + Service`
を複数並べたいケース向けの Helm chart です。既定では、すべての instance を
同じ main namespace / jobs namespace に置き、session PVC claim も共有します。

chart 全体として、既定で次を生成します。

- shared main namespace
- shared jobs namespace
- shared session PVC

各 `instances[]` エントリは、既定で次を 1 セット生成します。

- instance ごとに一意な ServiceAccount / RBAC
- instance ごとに一意な `control-plane-env` / `control-plane-instance-env` / `control-plane-config`
- workspace PVC
- `control-plane-<instance.name>` Deployment
- `control-plane-<instance.name>` Service

workspace PVC / Secret / Service も、instance 側で明示 override しない限り
`<base>-<instance.name>` で名前分離されます。複数 repo を持つ場合は `instances[]`
を増やしてください。

## 使い方

まず最低限、shared namespace と session PVC の RWX storage class、各 instance の
SSH 公開鍵を上書きします。

```yaml
global:
  namespace: copilot-workspaces
  jobNamespace: copilot-workspaces-jobs
  session:
    storageClassName: nfs-rwx

instances:
  - name: repo-a
    auth:
      sshPublicKey: |
        ssh-ed25519 AAAA... repo-a

  - name: repo-b
    auth:
      existingSecretName: repo-b-auth
    workspace:
      existingClaim: repo-b-workspace-pvc
```

```bash
helm upgrade --install control-plane deploy/helm/control-plane \
  -f my-values.yaml
```

既定では、すべての instance が `global.namespace` と `global.jobNamespace` を
共有します。Session PVC は `global.session.claimName` を共有しつつ、
`copilot-config.json`、`command-history-state.json`、`session-state`、
SSH auth/host keys は `instances/<name>/...` 配下へ自動で分離されます。
GitHub CLI / SSH client state は `global.session.{ghSubPath,sshSubPath}` を使うため、
必要なら `instances[].session` で repo ごとに分けてください。

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

- `global.namespace` / `global.jobNamespace`: instance 群を置く共有 namespace
- `instances[].image`: repo ごとの image tag / pullPolicy
- `instances[].service`: Service の明示名、type、port
- `instances[].workspace`: workspace PVC claim 名、size、storage class、subPath
- `global.session`: 共有 session PVC の claim 名、size、storage class
- `instances[].session`: repo ごとの stateSubPath や GH / SSH subPath override
- `instances[].auth.existingSecretName`: Secret を chart 外で管理したい場合
- `instances[].controlPlaneEnv`: runtime 用 ConfigMap の追加 override
- `instances[].instanceEnv`: kustomize replacement 相当の派生 env に対する追加 override

PVC は既定で `helm.sh/resource-policy: keep` を付け、chart uninstall で誤って
消えないようにしています。
