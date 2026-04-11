# Helm chart for multi-repository control planes

`deploy/helm/control-plane/` は、repo ごとに `copilot ACP + web backend/frontend +
workspace PVC + Service` を複数並べたいケース向けの Helm chart です。既定では、すべての instance を
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
- `control-plane-web-<instance.name>` Deployment
- `control-plane-web-<instance.name>` Service

workspace PVC と Service は、instance 側で明示 override しない限り
`<base>-<instance.name>` で名前分離されます。Secret と `control-plane-config` は
global 値をそのまま使う限り shared resource を使い、instance override を入れた
ときだけ per-instance resource を追加します。複数 repo を持つ場合は `instances[]`
を増やしてください。

## 使い方

まず最低限、shared namespace と session PVC の RWX storage class、各 instance の
必要な認証情報を上書きします。

```yaml
global:
  namespace: copilot-workspaces
  jobNamespace: copilot-workspaces-jobs
  auth:
    ghGithubToken: github_pat_... shared-token
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
共有します。Session PVC は `global.session.claimName` を共有しつつ、
`copilot-config.json`、`command-history-state.json`、`session-state`、
SSH 互換 state / host keys も `instances/<name>/...` 配下へ自動で分離されます。
GitHub CLI / SSH client state は `global.session.{ghSubPath,sshSubPath}` を使うため、
必要なら `instances[].session` で repo ごとに分けてください。

chart-managed な `global.auth` / `instances[].auth` に `ghGithubToken` や
`ghHostsYml` を入れた場合は、Deployment 側の `GH_GITHUB_TOKEN_FILE` /
`GH_HOSTS_YML_FILE` も自動で `/var/run/control-plane-auth/...` へ向くように
注入されます。`gh-hosts.yml` は `gh-github-token` より優先されるため、
両方を入れた場合も追加の `controlPlaneEnv` override は不要です。逆に
`existingSecretName` で chart 外の Secret を使う場合は、その Secret の中身を
chart が推測できないため、非標準 key/path を使うなら明示 override してください。

## runtime env の設定先

Git の `user.name` / `user.email`、`TZ`、Execution Pod の startup script は、
shared な `control-plane-env` と、instance ごとの
`control-plane-instance-env-<name>` overlay へ分かれて入ります。Helm では
次の 2 箇所から設定します。

| 用途 | values のキー | 反映先 |
| --- | --- | --- |
| 全 instance 共通の既定値 | `global.controlPlaneEnv` | shared `control-plane-env` ConfigMap |
| repo ごとの上書き | `instances[].controlPlaneEnv` | 対象 instance の `control-plane-instance-env-<name>` ConfigMap |

`instances[].instanceEnv` は workspace PVC 名や ACP / web host のような
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
      ghGithubToken: github_pat_... repo-a

  - name: repo-b
    auth:
      ghHostsYml: |
        github.com:
          oauth_token: github_pat_... repo-b
          git_protocol: ssh
          user: octocat
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
- `instances[].service`: internal ACP Service の明示名、type、port
- `instances[].webService`: browser / API 向け Service の明示名、type、port
- `instances[].workspace`: workspace PVC claim 名、size、storage class、subPath
- `global.session`: 共有 session PVC の claim 名、size、storage class
- `instances[].session`: repo ごとの stateSubPath や GH / SSH subPath override
- `global.auth`: shared `control-plane-auth` Secret
- `instances[].auth.existingSecretName`: Secret を chart 外で管理したい場合
- `instances[].auth`: token や、必要なら SSH 公開鍵を repo ごとに変えたい場合だけ per-instance Secret を作る
- `global.controlPlaneConfigJson`: shared `control-plane-config` ConfigMap
- `instances[].controlPlaneConfigJson`: repo ごとの config overlay が必要な場合だけ per-instance ConfigMap を作る
- `instances[].controlPlaneEnv`: runtime 用 ConfigMap の追加 override
- `instances[].instanceEnv`: kustomize replacement 相当の派生 env に対する追加 override

PVC は既定で `helm.sh/resource-policy: keep` を付け、chart uninstall で誤って
消えないようにしています。
