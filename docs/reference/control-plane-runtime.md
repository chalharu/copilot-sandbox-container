# Control Plane runtime reference

このページは、current-cluster / sample manifest / smoke test で参照する
runtime path と state の配置をまとめた Reference です。
背景説明は `docs/explanation/knowledge.md` を参照してください。
操作手順は `docs/how-to-guides/cookbook.md` を参照してください。

## 1. Login shell へ渡す runtime surface

entrypoint は `~/.config/control-plane/runtime.env` を生成し、login shell へ
少なくとも次を渡します。

- `TZ` で指定した IANA timezone
- UTF-8 locale を保証する `LANG=C.UTF-8` と `LC_CTYPE=C.UTF-8`
- 監査ログ SQLite DB の path と record cap
- Secret / ConfigMap 由来の file path
- Job 実行先 namespace と mode の既定値
- fast execution pod の enable flag、runtime image、bootstrap image、timeout、resource limit
- `--mount-file` で別 Job image へ逃がす JS/TS Biome hook 用の `CONTROL_PLANE_BIOME_HOOK_IMAGE`
- compile-heavy Rust hook 用の `CONTROL_PLANE_RUST_HOOK_IMAGE`
- 現在の Control Plane Pod 名 / namespace / UID / node 名
- exec policy 用の `LD_PRELOAD` と rule path

## 2. 永続化する state

sample manifest の既定値では、次の 2 つを分けます。

- RWX の copilot session PVC
- RWO の `/workspace` PVC

copilot session PVC へまとめるものは次のとおりです。

- `~/.copilot/command-history-state.json`
- `~/.copilot/session-state`
- `~/.copilot/restart`
- `~/.copilot/session-state/session-exec.json`
- `~/.copilot/session-state/audit/audit-log.db`
- `~/.config/gh`
- `~/.config/control-plane/ssh-auth/authorized_keys`
- `~/.ssh`
- `/var/lib/control-plane/ssh-host-keys`

`~/.copilot/config.json` は session PVC へは置きません。entrypoint が startup ごとに
ephemeral な実効 config を作り直し、runtime 中の Copilot 側更新もその writable path に
反映させます。古い PVC 上の `state/copilot-config.json` が残っていても参照しません。

`session-exec.json` には、hook rewrite が使う session key ごとの Execution Pod 名 /
Pod IP / auth token が入ります。incoming SSH auth は
`~/.config/control-plane/ssh-auth/authorized_keys` へ切り出して同じ PVC に残します。
`~/.ssh/authorized_keys` は互換 symlink にとどめます。これにより delegated exec pod
が共有する client-side SSH state から切り離します。
`sshd` 自体は PVC 上の private host key をそのまま読みません。startup ごとに
`/run/control-plane/ssh-host-keys` へ root-only copy を staging してから使います。
storage backend が persistent file に group bit を残す場合でも、再起動を壊しません。

監査ログの保持件数は `control-plane-env` ConfigMap の
`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS`（既定 `10000`）で調整します。
上限を超えた場合は、次の tool hook 実行時に古いレコードから削除します。
件数はおおむね上限の 3/4 件まで戻します。

## 3. 永続化しない state と runtime cache

次は emptyDir などの再生成可能な領域へ逃がします。

- `~/.copilot/tmp`
- Screen socket
- `/var/tmp/control-plane`
- Rust の `cargo-target` など再生成可能な cache

代表 path は次のとおりです。

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

`COPILOT_CONFIG_JSON_FILE` で渡した JSON object は、startup 時に毎回
ephemeral な `~/.copilot/config.json` の初期値として書き込みます。

### Secret

- `control-plane-auth`: `ssh-public-key` と認証系の Secret 値を startup 専用 input として供給
- `gh` 認証は `gh-github-token` または `gh-hosts.yml`
- `copilot-github-token`: Copilot token を startup 時に注入する場合だけ保持

`control-plane-auth` 配下の mounted file は entrypoint が起動時に消費します。
interactive shell からの direct read は exec policy が拒否します。
`GH_HOSTS_YML_FILE` があれば、その file を優先します。
無ければ `GH_GITHUB_TOKEN_FILE` から最小 `~/.config/gh/hosts.yml` を生成します。
`COPILOT_GITHUB_TOKEN_FILE` は private runtime token file へ移します。
以後は raw mount を読ませません。

sample manifest の fast execution pod は専用の
`ghcr.io/chalharu/copilot-sandbox-container/exec-pod:<tag>` image を使います。
`/usr/local/bin/control-plane-exec-api serve` を直接起動し、initContainer /
node-scoped environment PVC / chroot は使いません。workspace PVC は
`CONTROL_PLANE_WORKSPACE_MOUNT_PATH`（既定 `/workspace`）へ直接 mount します。
`gh` と SSH の shared session mount も remote HOME (`/root`) 配下へ直接 mount します。
exec-pod image には `bash` / `git` / `gh` / `kubectl` / `sudo` / `sccache` と
bundled hook が含まれます。remote HOME には `.gitconfig` を毎回生成します。
`.cargo/config.toml` は image default または追加 volume mount で供給し、Rust の
`target-dir` と sccache 用 cache を `/var/tmp/control-plane` 配下へ寄せます。

追加の Kubernetes volume は
`CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON` に渡します。
追加の volumeMount は
`CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON` に渡します。
値は core/v1 `Volume` / `VolumeMount` の JSON array です。
runtime は JSON array であることを検証します。volume 名は built-in
(`workspace`, `copilot-session`) と重複できません。mount は既知 volume を参照し、
`mountPath` は絶対 path にします。
`hostPath` volume と、workspace / shared `gh` / SSH / service account token などの
予約済み mount path と重なる追加 mount は拒否します。
sample では generic ephemeral volume `ephemeral-storage` を
`/var/tmp/control-plane` に mount し、Execution Pod ごとに初期化します。
`CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT` を設定すると、各 Execution Pod は
serve 前にその値を `/bin/sh -lc` として実行します。値は inline
command でも script path でも構いません。image pull と startup script に時間が
かかりうるため、
Execution Pod は gRPC startupProbe と長めの
`CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT` を前提にしています。
Pod 自体の OwnerReference / node pin には Deployment の downward API env
(`CONTROL_PLANE_POD_*`, `CONTROL_PLANE_NODE_NAME`) を使います。
`CONTROL_PLANE_POD_IP` は reverse `postToolUse` API の到達先に使います。
`CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT` を設定すると、Execution Pod は
その ServiceAccount で起動します。in-cluster の service account token も
mount します。sample 既定では `control-plane-exec` を使います。
別 namespace の workload 操作用権限は、`copilot-sandbox-jobs` の
`control-plane-exec-workloads` Role に限定します。delegated shell の default
namespace は owner Pod 側のままです。別 namespace のリソースは
`kubectl -n ...` で明示してください。

## 5. Hook と Git policy surface

entrypoint は `COPILOT_HOME=/var/lib/control-plane/managed-runtime/copilot-home` を保ちつつ、
その path 自体を `~/.copilot` への root-owned symlink にします。Copilot 側は writable な
`~/.copilot/config.json` を直接更新でき、bundled hook は root-owned な
`~/.copilot/hooks -> /usr/local/share/control-plane/hooks` で固定します。
`~/.copilot/` は sticky directory として管理するため、Copilot user は他の
state を更新できても `hooks` symlink 自体は差し替えられません。

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

hook 側は `sh -c` / `bash -lc` を unwrap します。exec 側は `execve`、
`execveat`、`posix_spawn`、`posix_spawnp` を監視します。Node.js の
child-process や shell script 経由でも同じ policy を適用できます。
pre-commit では bundled `postToolUse` linter を走らせます。必要なら repo ごとの
`.github/git-hooks/pre-commit` / `.github/git-hooks/pre-push` も続けて実行します。

bundled `preToolUse/exec-forward` は、
`CONTROL_PLANE_FAST_EXECUTION_ENABLED=1` のときに有効です。
Copilot CLI の `bash` tool 自体はそのまま使います。bundled `preToolUse` hook と
runtime が、内部 helper の `control-plane-session-exec proxy` を呼んで
same-namespace / same-node の Execution Pod へ自動委譲します。operator や
agent が `bash` tool からこの helper を直接呼ぶ想定はありません。helper は
same-namespace / same-node の Execution Pod を on-demand で作成または再利用します。
`/workspace` PVC を共有したまま、gRPC 経由で転送します。
Execution Pod は dedicated exec-pod image を起点にします。
`postToolUse` hook は Execution Pod 内で
ローカル実行しません。`CONTROL_PLANE_POST_TOOL_USE_FORWARD_*` で Control Plane Pod
側の限定 reverse API へ転送します。そのため hook 実行に必要な追加 tool を
exec-pod image へ複製しません。Exec API は per-pod token が必須です。
delegated command 自体は `CONTROL_PLANE_FAST_EXECUTION_RUN_AS_{UID,GID}` で指定した
非 root UID/GID へ drop してから実行します。delegated stdout の先頭には
submit された command line をそのまま出力します。remote 実行時でも何を流したかを
追跡できます。`control-plane-exec-api serve` は request / response を
`timestamp` (UNIX epoch ms) と `requestId` 付きの JSON 1 行で標準出力へ出します。
Kubernetes の pod log から追跡できます。
gRPC 経路は cluster 内 plaintext を前提にしています。
flat network ではなく、pod-to-pod 通信を信用できる namespace / CNI で
使ってください。bundled `sessionEnd/cleanup` は同じ session key で明示 cleanup
を行います。Control Plane Pod 側の OwnerReference でも Pod 漏れを抑えます。
bash hook では `CONTROL_PLANE_HOOK_SESSION_KEY="$PPID"` を渡します。
runtime はこの値を transient shell PID ではなく、
Copilot session 側の親プロセス識別子として扱います。
同じ親プロセスの start time と組み合わせた scope ごとに、
UUIDv4 の推測困難な session key を `~/.copilot/session-state/` 配下へ解決します。

bundled `control-plane-biome` は次のように動きます。

- `CONTROL_PLANE_BIOME_HOOK_IMAGE` があれば、changed file と repo root の
  `biome.jsonc` / `.gitignore` だけを `control-plane-run --mount-file` で
  Kubernetes Job へ stage する。
- その Job で official `ghcr.io/biomejs/biome` image 上の `biome check` を
  実行する。
- root `biome.jsonc` では JS/TS/JSON 系だけを対象にする。
- `target/`、`build/`、`dist/`、`node_modules/` などの大きい出力 path は
  force-ignore する。
- cluster 側で Job が使えない場合だけ、local `biome` /
  `npx @biomejs/biome` fallback に戻る。

bundled `postToolUse/control-plane-rust.sh` は、`CONTROL_PLANE_RUST_HOOK_IMAGE` が
あれば `control-plane-run` 経由でその image に cargo work を逃がします。
`fmt` / `fmt-check` のような軽い処理は local でも動きます。`clippy` や `test`
のような compile-heavy な処理は別です。slim 化した control-plane image に
build toolchain は戻しません。専用 image を既定にしてください。

sample manifest では、この経路のために control-plane ServiceAccount へ
same-namespace Pod の `create/delete/get/list/watch` 権限を付けます。Exec Pod から
in-cluster kubectl も使いたい場合は、別の `control-plane-exec` ServiceAccount を
`CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT` に設定します。
`copilot-sandbox-jobs` 側では Deployment / Service / Job / Pod に限定した
`control-plane-exec-workloads` Role へ bind します。shared namespace へそのまま
広げず、dedicated namespace を前提にしてください。

## 6. Bundled skill surface

bundled skill は image に同梱し、起動時に `~/.copilot/skills/` へ copy 同期
します。現在は repo change delivery 系の補助 skill だけを残し、runtime / hook
まわりは image 内の script と binary に寄せています。symlink ではなく copy 同期を
使い、directory / file mode を明示的に整えることで current-cluster smoke でも
安定して参照できます。

## 7. Bundled agent surface

bundled agent も image に同梱し、起動時に `~/.copilot/agents/` へ copy 同期
します。現在は次を同梱しています。

- generic な implementation agent
- KISS/DRY・SOLID・security・architecture 向け review agent 群
- review coordinator agent
- 実装前の調査・設計専用の pre-implementation design agent

skill と同じく user-owned copy を使って file mode を明示的に整えています。
これにより、
standalone / Kubernetes Job のどちらでも agent file を安定して参照できます。

## 8. Kubernetes Job file transfer

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
