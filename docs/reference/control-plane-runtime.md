# Control Plane runtime reference

このページは、current-cluster / sample manifest / smoke test で
「何がどこに置かれるか」を引くための Reference です。
背景説明は `docs/explanation/knowledge.md`、操作手順は
`docs/how-to-guides/cookbook.md` を参照してください。

## 1. Login shell へ渡す runtime surface

entrypoint は `~/.config/control-plane/runtime.env` を生成し、login shell へ
少なくとも次を渡します。

- `TZ` で指定した IANA timezone
- UTF-8 locale を保証する `LANG=C.UTF-8` と `LC_CTYPE=C.UTF-8`
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
- `~/.config/control-plane/ssh-auth/authorized_keys`
- `~/.ssh`
- `/var/lib/control-plane/ssh-host-keys`

`session-exec.json` には、hook rewrite が使う session key ごとの Execution Pod
名 / Pod IP / auth token / environment PVC 名 が入ります。incoming SSH auth は
`~/.config/control-plane/ssh-auth/authorized_keys` へ切り出して同じ PVC に残し、
`~/.ssh/authorized_keys` は互換 symlink にとどめることで、delegated exec pod が
共有する client-side SSH state から切り離します。
`sshd` 自体は PVC 上の private host key をそのまま読まず、startup ごとに
`/run/control-plane/ssh-host-keys` へ root-only copy を staging してから使います。
これで、storage backend が persistent file に group bit を残す場合でも再起動を壊しません。

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
Rust 製 `control-plane-exec-api` と bundled Git hook を node-scoped な
RWO PVC (`CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_PVC_PREFIX` で命名) の
`/environment` へ初回 staging します。本体 container は cached binary を
pod-local な `/control-plane/bin/control-plane-exec-api` へ staging して起動し、
`/environment/root` を
chroot 先として初回だけ runtime image の rootfs を複製し、そこへ
`bash` / `git` / `gh` / `openssh-client` を入れます。以後の session pod は
同じノード上でその chroot を再利用するため、毎回の package install を避けられます。
`CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT` を設定すると、各 Execution Pod は
serve 前にその値を chroot 内で `/bin/sh -lc` として実行します。inline command
でも script path でもよく、`apt-get install` のような追加セットアップを
差し込めます。
初回 bootstrap は数分かかりうるため、Execution Pod は gRPC startupProbe と
長めの `CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT` を前提にしています。
Pod 自体の OwnerReference / node pin には Deployment の downward API env
(`CONTROL_PLANE_POD_*`, `CONTROL_PLANE_NODE_NAME`) を使います。

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
node-scoped な `/environment` PVC を同じ node 上で共有し、`/environment/root`
の chroot runtime と cached `control-plane-exec-api`、`/environment/hooks/git`
を再利用します。
Exec API は per-pod token が必須で、delegated command 自体は
`CONTROL_PLANE_FAST_EXECUTION_RUN_AS_{UID,GID}` で指定した非 root UID/GID へ
drop してから実行します。delegated stdout の先頭には submit された command line
をそのまま出力するため、remote 実行時でも何を流したかを追跡できます。gRPC 経路は
cluster 内 plaintext を前提にしているため、
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
