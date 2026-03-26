# Control Plane runtime reference

このページは、current-cluster / sample manifest / smoke test で
「何がどこに置かれるか」を引くための Reference です。
背景説明は `docs/explanation/knowledge.md`、操作手順は
`docs/how-to-guides/cookbook.md` を参照してください。

## 1. Login shell へ渡す runtime surface

entrypoint は `~/.config/control-plane/runtime.env` を生成し、login shell へ
少なくとも次を渡します。

- rootful Podman remote service 関連の env
- `TZ` で指定した IANA timezone
- Copilot CPU cap
- 監査ログ SQLite DB の path と record cap
- `sccache` S3 backend の endpoint / bucket / credential file path（設定時）
- Secret / ConfigMap 由来の file path
- Job 実行先 namespace と mode の既定値
- exec policy 用の `LD_PRELOAD` と rule path

## 2. 永続化する state

sample manifest の既定値では、次の 3 つを分けます。

- RWX の copilot session PVC
- RWO の `/workspace` PVC
- RWO の dedicated `sccache` object-store PVC（standalone Garage Deployment 用）

copilot session PVC へまとめるもの:

- `~/.copilot/config.json`
- `~/.copilot/command-history-state.json`
- `~/.copilot/session-state`
- `~/.copilot/session-state/audit/audit-log.db`
- `~/.copilot/session-state/audit/audit-analysis.db`
- `~/.config/gh`
- `~/.ssh`
- `/var/lib/control-plane/ssh-host-keys`

`control-plane-config` の `copilot-config.json` overlay に
`controlPlane.auditAnalysis` を入れると、bundled
`audit-log-analysis` skill と lifecycle analysis hooks
(`agentStop` / `subagentStop` / `sessionEnd` / `errorOccurred`) が
同じ永続 state を参照します。

dedicated sccache PVC は current-cluster の long-running Rust Job 向け
standalone Garage Deployment 用です。sample manifest では
`ReadWriteOnce` の 5Gi claim を `/var/lib/garage` へ mount し、
Garage bucket quota を `4294967296` bytes に抑えて 4GiB までに制限します。
Rust Job 自体は PVC を mount せず、`SCCACHE_BUCKET`、`SCCACHE_ENDPOINT`、
`AWS_ACCESS_KEY_ID_FILE`、`AWS_SECRET_ACCESS_KEY_FILE` を受け取って cluster 内の
`garage-s3` Service へ接続します。Garage 本体は公式 `dxflrs/garage:v2.2.0`
image を使い、initContainer が `garage.toml` を生成し、companion bootstrap
container が single-node layout / key / bucket / lifecycle を idempotent に
適用します。古い cache object は S3 lifecycle expiration で自動削除します。object-store mode
を無効化した場合も、`sccache` 自体は
`/var/tmp/containerized-rust/<repo>/<branch>/sccache` の ephemeral path を使い、
`/workspace` PVC には `cargo` / `rustup` cache だけを残します。

監査ログの保持件数は `control-plane-env` ConfigMap の
`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）で調整し、
上限を超えた場合は次の tool hook 実行時に古いレコードから削除して
おおむね上限の 3/4 件まで戻します。

## 3. 永続化しない state と Podman cache

次は emptyDir などの再生成可能な領域へ逃がします。

- `~/.copilot/tmp`
- Screen socket
- rootless Podman の graphroot / runtime dir / runroot
- rootful-service の graphroot cache と runtime dir

代表 path:

- rootless graphroot: `/var/tmp/control-plane/rootless-podman/<driver>/storage`
- rootful-service graphroot:
  `/var/lib/control-plane/rootful-podman/rootful-<driver>/storage`
- rootful-service runtime dir / runroot:
  `/var/tmp/control-plane/rootful-<driver>`

互換用に `~/.copilot/containers` を残す場合もありますが、実体の graphroot は
上記の disposable path 側です。current-cluster の rootful-service は既定
driver を `overlay` にし、`/dev/fuse` がある場合だけ `fuse-overlayfs` を
使います。

## 4. ConfigMap / Secret の注入面

### ConfigMap

- `control-plane-config`: `copilot-config.json` の JSON object overlay
- `control-plane-env`: namespace / PVC / Job 既定値 / file path / sccache S3 endpoint のような
  非機密 env

`COPILOT_CONFIG_JSON_FILE` で渡した JSON object は、PVC 上の既存
`~/.copilot/config.json` へ deep-merge されます。

### Secret

- `control-plane-auth`: `ssh-public-key` と認証系の Secret 値
- `garage-admin-auth`: Garage bootstrap 用の admin token / rpc secret
- `garage-sccache-auth`: `sccache` S3 access key / secret key
- `gh` 認証は `gh-github-token` または `gh-hosts.yml`
- 必要に応じて `copilot-github-token`、DockerHub 認証情報も保持

`GH_HOSTS_YML_FILE` があればその file を優先し、無ければ
`GH_GITHUB_TOKEN_FILE` から最小 `~/.config/gh/hosts.yml` を生成します。

## 5. Hook と Git policy surface

entrypoint は bundled Copilot hook を root-owned な `COPILOT_HOME` 配下へ
配置し、互換用に `~/.copilot/hooks` からも参照できるようにします。

Git 側では次を固定します。

- root-owned な `GIT_CONFIG_GLOBAL` を生成する
- `core.hooksPath` を `/usr/local/share/control-plane/hooks/git` へ向ける
- `~/.gitconfig` は互換用 symlink にとどめる

この経路で、少なくとも次を一貫して拒否します。

- `main` / `master` への commit / push
- `git commit --no-verify`
- `git push --no-verify`
- `git -c core.hooksPath=...` や同等の hooksPath override
- `git push --force` / `-f`
- 危険な Git config 環境変数 override

hook 側は `sh -c` / `bash -lc` を unwrap し、exec 側は `execve`、
`execveat`、`posix_spawn`、`posix_spawnp` を監視するため、Node.js の
child-process や shell script 経由でも同じ policy を適用できます。
pre-commit では bundled `postToolUse` linter を走らせ、必要なら repo ごとの
`.github/git-hooks/pre-commit` / `.github/git-hooks/pre-push` も続けて
実行します。

## 6. Bundled skill surface

bundled skill は image に同梱し、起動時に `~/.copilot/skills/` へ copy 同期
します。

- `control-plane-operations` や `audit-log-analysis` を `/workspace` と
  無関係に参照できる
- symlink ではなく copy 同期を使う
- `references/` を含む directory / file mode を明示的に整える
- current-cluster smoke では `references/` の可読性も確認する

## 7. Kubernetes Job file transfer

Kubernetes Job path の `--mount-file` は、ConfigMap ではなく SSH/SFTP +
`rclone` を使います。

- init container が入力ファイルを pull する
- sidecar が Job 完了後に変更ファイルを push する
- write-back は Job 開始時の SHA-256 と完了時の現在値を比較する
- 外部更新と Job 側更新が衝突した場合は、黙って上書きせず staging area へ
  退避する

## 関連ドキュメント

- 最短導線: `README.md`
- 目的別の操作手順: `docs/how-to-guides/cookbook.md`
- 設計理由: `docs/explanation/knowledge.md`
- 代表ログ: `docs/reference/debug-log.md`
