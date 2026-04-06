# postToolUse hook

Copilot CLI の `postToolUse` hook をこのリポジトリ向けに最適化した設定です。

## Copilot hooks

Control Plane entrypoint は bundled hook JSON を root-owned な `COPILOT_HOME/hooks/` から読み、互換用に `~/.copilot/hooks/` symlink も張ります。`hooks.json` は `COPILOT_HOME` を優先して `hooks/postToolUse/main.mjs` を起動するため、repo ごとの `.github/hooks/` を置かなくても共通の `postToolUse` hook を保護された path から利用できます。`main.mjs` は標準入力を 1 回だけ読み、Git 差分を 1 回だけ取得し、対象ファイルの判定と linter の切り替えをまとめて行います。各 linter 実行では `TMPDIR` / `NODE_COMPILE_CACHE` / `NPM_CONFIG_CACHE` を `${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/hooks` 配下へ寄せ、hook 用の一時ファイルと cache を共通の一時ディレクトリへ集約します。

この hook は Copilot CLI から渡される JSON を stdin で受け取る前提です。`node ~/.copilot/hooks/postToolUse/main.mjs` を対話端末で直接実行すると、stdin の EOF が来るまで `readStdin()` が待つため、プロンプトが返ってこないように見えます。確認したいときは `printf '%s' '{"cwd":"/workspace","toolResult":{"resultType":"success"}}' | node ~/.copilot/hooks/postToolUse/main.mjs` のように JSON を pipe するか、空入力のまま EOF (`Ctrl-D`) を送ってください。

実行対象は bundled hook と同じ `postToolUse` ディレクトリ内の `linters.json`（このリポジトリでは `containers/control-plane/hooks/postToolUse/linters.json`）と、repo root の `.github/linters.json` をマージして定義します。`.github/linters.json` が優先され、同じ `id` を持つ `tools` / `pipelines` は `.github` 側の定義で置き換えます。この JSON は `tools` と `pipelines` の 2 セクションだけを持ちます。`tools` は実行コマンドと引数を含む concrete な定義で、必要に応じて対象ファイルを引数に付けないコマンドも表現できます。`pipelines` は regex matcher 配列と実行順、各 step の fallback tools をまとめて表します。

この構成により、`postToolUse` が複数コマンドへ分かれている場合に発生するプロセス起動、stdin 解析、Git 差分取得の重複を避けられます。dirty な対象ファイルは `.git/.copilot-hooks/post-tool-use-state.json` の署名と比較し、今回変わったものだけを処理します。pipeline は上から評価され、各ファイルは最初にマッチした pipeline にだけ割り当てられます。matcher は regex 配列のみを受け付け、内部では `|` で結合した 1 つの `RegExp` として扱います。

Markdown は `markdownlint-cli2 --fix` → 再lint、JS/TS 系 (`.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`) は `Biome check --write` → `Oxlint --fix` → `Biome check --write` → 再check、YAML は bundled control-plane toolchain の `yamllint -c .yamllint` で検査します。Python は `ruff format` → `ruff check --fix` → `ruff format` → `ruff check` の順で動き、Rust は bundled `control-plane-rust.sh` helper を呼んで `fmt` / `clippy --fix` / `clippy -D warnings` を各 crate に対して実行します。Dockerfile は `hadolint` で検査します。自動修正で解決した内容は表示せず、fix 後も残った違反だけを表示します。

各 step はローカル CLI を優先し、必要なら別ツールや `npx` 実行へ順に fallback できます。たとえば JS/TS lint は `oxlint -> eslint -> eslint-npx -> oxlint-npx` の順で試せるようにしています。
