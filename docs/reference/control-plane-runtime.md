# Control Plane runtime reference

このページは、current-cluster / sample manifest / smoke test で
「何がどこに置かれるか」を引くための Reference です。
背景説明は `docs/explanation/knowledge.md`、操作手順は
`docs/how-to-guides/cookbook.md` を参照してください。

## 1. Login shell へ渡す runtime surface

entrypoint は `~/.config/control-plane/runtime.env` を生成し、login shell へ
少なくとも次を渡します。

- `TZ` で指定した IANA timezone
- 監査ログ SQLite DB の path と record cap
- Secret / ConfigMap 由来の file path
- Job 実行先 namespace と mode の既定値
- fast execution pod の enable flag、runtime image、bootstrap image、timeout、resource limit
- compile-heavy Rust hook 用の `CONTROL_PLANE_RUST_HOOK_IMAGE`
- 現在の Control Plane Pod 名 / namespace / UID / node 名
- exec policy 用の `LD_PRELOAD` と rule path

## 2. 永続化する state

sample manifest の既定値では、次の 2 つを分けます。

- RWX の copilot session PVC
- RWO の `/workspace` PVC

copilot session PVC へまとめるもの:

- `~/.copilot/config.json`
- `~/.copilot/command-history-state.json`
- `~/.copilot/session-state`
- `~/.copilot/session-state/session-exec.json`
- `~/.copilot/session-state/audit/audit-log.db`
- `~/.config/gh`
- `~/.ssh`
- `/var/lib/control-plane/ssh-host-keys`

`session-exec.json` には、hook rewrite が使う session key ごとの Execution Pod
名 / Pod IP / auth token / owner metadata / node 名 / runtime image が入ります。

監査ログの保持件数は `control-plane-env` ConfigMap の
`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）で調整し、
上限を超えた場合は次の tool hook 実行時に古いレコードから削除して
おおむね上限の 3/4 件まで戻します。

## 3. 永続化しない state と runtime cache

次は emptyDir などの再生成可能な領域へ逃がします。

- `~/.copilot/tmp`
- Screen socket
- `/var/tmp/control-plane`
- Rust の `cargo-target` など再生成可能な cache

代表 path:

- temp / runtime cache root: `/var/tmp/control-plane`
- bundled Rust target dir: `/var/tmp/control-plane/cargo-target`
- containerized Rust ephemeral state:
  `/var/tmp/containerized-rust/<repo>/<branch>/...`

再生成可能な cache は上記の disposable path 側へ寄せ、session PVC と
`/workspace` PVC には再開に必要な state だけを残します。

## 4. ConfigMap / Secret の注入面

### ConfigMap

- `control-plane-config`: `copilot-config.json` の JSON object overlay
- `control-plane-env`: namespace / PVC / Job 既定値 / file path / fast execution pod
  設定のような非機密 env

`COPILOT_CONFIG_JSON_FILE` で渡した JSON object は、PVC 上の既存
`~/.copilot/config.json` へ deep-merge されます。

### Secret

- `control-plane-auth`: `ssh-public-key` と認証系の Secret 値を startup 専用 input として供給
- `gh` 認証は `gh-github-token` または `gh-hosts.yml`
- 必要に応じて `copilot-github-token` も保持

`control-plane-auth` 配下の mounted file は entrypoint が起動時に消費し、interactive shell からの direct read は exec policy が拒否します。`GH_HOSTS_YML_FILE` があればその file を優先し、無ければ `GH_GITHUB_TOKEN_FILE` から最小 `~/.config/gh/hosts.yml` を生成します。`COPILOT_GITHUB_TOKEN_FILE` は private runtime token file へ移し、以後は raw mount を読ませません。

sample manifest の fast execution pod では、runtime image とは別に
`CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE` を指定し、initContainer が
Rust 製 `control-plane-exec-api` と bundled Git hook を `emptyDir` へ展開します。
本体 container はその staged binary を起動し、gRPC 経由の bootstrap で
`bash` / `git` / `gh` を必要に応じて導入します。Pod 自体の OwnerReference /
node pin には Deployment の downward API env (`CONTROL_PLANE_POD_*`,
`CONTROL_PLANE_NODE_NAME`) を使います。

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

bundled `preToolUse/exec-forward` は、`CONTROL_PLANE_FAST_EXECUTION_ENABLED=1`
のとき Copilot CLI の `bash` tool を `control-plane-session-exec proxy` へ
書き換えます。helper は same-namespace / same-node の Execution Pod を
on-demand で作成または再利用し、`/workspace` PVC を共有したまま
gRPC 経由で転送します。Execution Pod は任意の Linux image を起点にしつつ、
bootstrap image から受け取った Rust binary と Git hook を使って初期化されます。
Exec API は per-pod token が必須で、delegated command 自体は
`CONTROL_PLANE_FAST_EXECUTION_RUN_AS_{UID,GID}` で指定した非 root UID/GID へ
drop してから実行します。gRPC 経路は cluster 内 plaintext を前提にしているため、
flat network ではなく pod-to-pod 通信を信用できる namespace / CNI で使ってください。
bundled `sessionEnd/cleanup` は同じ session key で明示 cleanup を行い、
Control Plane Pod 側の OwnerReference でも Pod 漏れを抑えます。bash hook では
`CONTROL_PLANE_HOOK_SESSION_KEY="$PPID"` を渡し、
transient shell PID ではなく Copilot session 側の親プロセスを key に使います。

bundled `postToolUse/control-plane-rust.sh` は、`CONTROL_PLANE_RUST_HOOK_IMAGE` が
あれば `control-plane-run` 経由でその image に cargo work を逃がします。
`fmt` / `fmt-check` のような軽い処理は local でも動きますが、`clippy` や
`test` のような compile-heavy な処理は slim 化した control-plane image に
build toolchain を戻さないため、専用 image を既定にしてください。

sample manifest では、この経路のために control-plane ServiceAccount へ
same-namespace Pod の `create/delete/get/list/watch` 権限を付けます。shared
namespace へそのまま広げず、dedicated control-plane namespace を前提にしてください。

## 6. Bundled skill surface

bundled skill は image に同梱し、起動時に `~/.copilot/skills/` へ copy 同期
します。現在は repo change delivery 系の補助 skill だけを残し、runtime / hook
まわりは image 内の script と binary に寄せています。symlink ではなく copy 同期を
使い、directory / file mode を明示的に整えることで current-cluster smoke でも
安定して参照できます。

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
