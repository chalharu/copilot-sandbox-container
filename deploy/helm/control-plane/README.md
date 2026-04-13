# Helm chart for multi-repository control planes

`deploy/helm/control-plane/` は、repo ごとに `copilot + workspace PVC + Service`
を複数並べたいケース向けの Helm chart です。既定では、すべての instance を
同じ main namespace / jobs namespace に置き、session PVC claim も共有します。

chart 全体として、既定で次を生成します。

- shared main namespace
- shared jobs namespace
- shared session PVC
- shared `control-plane-env` ConfigMap
- shared `control-plane-config` ConfigMap
- shared `control-plane-auth` Secret
- shared ServiceAccount / RBAC

各 `instances[]` エントリは、既定で次を 1 セット生成します。

- instance ごとに一意な `control-plane-instance-env`
- workspace PVC
- `control-plane-<instance.name>` Deployment
- `control-plane-<instance.name>` Service

workspace PVC と Service は、instance 側で明示 override しない限り
`<base>-<instance.name>` で名前分離されます。Secret と `control-plane-config` は
global 値をそのまま使う限り shared resource を使い、instance override を入れた
ときだけ per-instance resource を追加します。複数 repo を持つ場合は `instances[]`
を増やしてください。

## 使い方

まず最低限、shared namespace と session PVC の RWX storage class、各 instance の
SSH 公開鍵を上書きします。

```yaml
global:
  namespace: copilot-workspaces
  jobNamespace: copilot-workspaces-jobs
  auth:
    sshPublicKey: |
      ssh-ed25519 AAAA... shared-login-key
  session:
    storageClassName: nfs-rwx

instances:
  - name: repo-a

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
共有します。Session PVC は `global.session.claimName` も共有します。
`copilot-config.json`、`command-history-state.json`、`session-state`、SSH auth/host
keys は `instances/<name>/...` 配下へ自動で分離されます。GitHub CLI / SSH client
state は `global.session.{ghSubPath,sshSubPath}` を使います。repo ごとに
分けたい場合は `instances[].session` で上書きしてください。

chart-managed な `global.auth` / `instances[].auth` に `ghGithubToken` を入れると、
Deployment 側の `GH_GITHUB_TOKEN_FILE` も自動で注入されます。
`GH_GITHUB_TOKEN_FILE` は
`/var/run/control-plane-auth/gh-github-token` を指します。
`ghHostsYml` を入れると、`GH_HOSTS_YML_FILE` も自動で注入されます。
`GH_HOSTS_YML_FILE` は `/var/run/control-plane-auth/gh-hosts.yml` を指します。
`gh-hosts.yml` は `gh-github-token` より優先されます。
両方を入れても追加の `controlPlaneEnv` override は不要です。
`existingSecretName` で chart 外の Secret を使う場合は、chart が中身を
推測できません。非標準 key/path を使うなら明示 override してください。

## runtime env の設定先

Git の `user.name` / `user.email`、`TZ`、Execution Pod の startup script は、
2 つの ConfigMap に分かれます。shared な `control-plane-env` と、instance
ごとの `control-plane-instance-env-<name>` overlay です。Helm では次の 2 箇所
から設定します。

| 用途 | values のキー | 反映先 |
| --- | --- | --- |
| 全 instance 共通の既定値 | `global.controlPlaneEnv` | shared `control-plane-env` ConfigMap |
| repo ごとの上書き | `instances[].controlPlaneEnv` | 対象 instance の `control-plane-instance-env-<name>` ConfigMap |

`instances[].instanceEnv` は workspace PVC 名や job-transfer host のような
chart 側の派生値向けなので、これらの設定先には使いません。

```yaml
global:
  controlPlaneEnv:
    CONTROL_PLANE_GIT_USER_NAME: Copilot Workspace Bot
    CONTROL_PLANE_GIT_USER_EMAIL: copilot@example.com
    TZ: Asia/Tokyo
    CONTROL_PLANE_BIOME_HOOK_IMAGE: ghcr.io/biomejs/biome:2.4.11
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
  managed global Git config へ書かれる。
- `TZ` は login shell と job tooling に渡される。
- `CONTROL_PLANE_BIOME_HOOK_IMAGE` は JS/TS 向け bundled Biome hook を
  Kubernetes Job の official Biome image へ逃がす。

- `CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT` は各 Execution Pod の chroot 内で
  `/bin/sh -lc` として実行される。
- 値は inline shell snippet でも、そこで見える script path でもよい。

## 主な override

- `global.namespace` / `global.jobNamespace`: instance 群を置く共有 namespace
- `instances[].image`: repo ごとの image tag / pullPolicy
- `instances[].service`: Service の明示名、type、port
- `instances[].workspace`: workspace PVC claim 名、size、storage class、subPath
- `global.session`: 共有 session PVC の claim 名、size、storage class
- `instances[].session`: repo ごとの stateSubPath や GH / SSH subPath override
- `global.auth`: shared `control-plane-auth` Secret
- `instances[].auth.existingSecretName`: Secret を chart 外で管理したい場合
- `instances[].auth`: SSH 公開鍵や token を repo ごとに変えたい場合だけ per-instance Secret を作る
- `global.controlPlaneConfigJson`: shared `control-plane-config` ConfigMap
- `instances[].controlPlaneConfigJson`: repo ごとの config overlay が必要な場合だけ per-instance ConfigMap を作る
- `instances[].controlPlaneEnv`: runtime 用 ConfigMap の追加 override
- `instances[].instanceEnv`: kustomize replacement 相当の派生 env に対する追加 override

PVC は既定で `helm.sh/resource-policy: keep` を付け、chart uninstall で誤って
消えないようにしています。
