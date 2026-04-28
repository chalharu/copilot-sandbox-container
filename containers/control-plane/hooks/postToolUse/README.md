# postToolUse hook

Copilot CLI の `postToolUse` hook を、このリポジトリ向けに最適化した設定です。
bundled hook と repo-local 設定を統合し、対象ファイルごとに linter pipeline を切り替えます。

## Copilot hooks

Control Plane entrypoint は bundled hook JSON を root-owned な
`COPILOT_HOME/hooks/` から読みます。互換用に `~/.copilot/hooks/` symlink も張ります。
`~/.copilot/` は sticky directory として管理します。そのため Copilot user は
他の state を更新できても、`hooks` symlink だけは差し替えできません。

`hooks.json` は `COPILOT_HOME` を優先して Rust 製の `hooks/postToolUse/main` を
起動します。repo ごとの `.github/hooks/` を置かなくても、共通の `postToolUse`
hook を保護された path から利用できます。この hook は標準入力を 1 回だけ読みます。
Git 差分も 1 回だけ取得します。対象ファイルの判定と linter の切り替えも、
1 回にまとめて行います。各 linter 実行では `TMPDIR` / `NODE_COMPILE_CACHE` /
`NPM_CONFIG_CACHE` を `${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/hooks`
配下へ寄せます。hook 用の一時ファイルと cache を共通の一時ディレクトリへ
集約します。

この hook は Copilot CLI から渡される JSON を stdin で受け取る前提です。
`~/.copilot/hooks/postToolUse/main` を対話端末で直接実行すると、stdin の EOF が
来るまで入力待ちになります。確認したいときは、次のように JSON を pipe します。

```bash
printf '%s' '{"cwd":"/workspace","toolResult":{"resultType":"success"}}' | ~/.copilot/hooks/postToolUse/main
```

空入力のまま EOF (`Ctrl-D`) を送る方法でも確認できます。

JS/TS/JSON 系の bundled lint は `control-plane-biome` を使います。repo root の
`biome.jsonc` と `.gitignore` を優先します。
`CONTROL_PLANE_BIOME_HOOK_IMAGE` が設定されていれば、changed file だけを
`control-plane-run --mount-file` で Kubernetes Job に stage します。
その Job で official `ghcr.io/biomejs/biome` image 上の Biome を実行します。
local fallback 時は `biome` CLI、無ければ `npx @biomejs/biome` を使います。

実行対象は bundled hook と同じ `postToolUse` ディレクトリ内の `linters.json` と、
repo root の `.github/linters.json` をマージして定義します。このリポジトリの
bundled 定義は `containers/control-plane/hooks/postToolUse/linters.json` にあります。
`.github/linters.json` が優先されます。同じ `id` を持つ `tools` / `pipelines`
は `.github` 側の定義で置き換えます。この JSON は `tools` と `pipelines` の
2 セクションだけを持ちます。`tools` は実行コマンド、引数、必要なら
runtime failure とみなす exit code を持つ concrete な定義です。対象ファイルを
引数に付けないコマンドも表現できます。`requiredRepoFiles` を持つ tool は、
そのうちどれか 1 つでも repo root に存在するときだけ実行します。`pipelines` は regex matcher 配列と
実行順、各 step の fallback tools、通常の lint failure label と runtime failure
label をまとめます。

この構成により、`postToolUse` が複数コマンドへ分かれている場合でも、プロセス起動や
stdin 解析、Git 差分取得の重複を避けられます。dirty な対象ファイルは
`.git/.copilot-hooks/post-tool-use-state.json` の署名と比較し、今回変わったものだけを
処理します。pipeline は上から評価され、各ファイルは最初にマッチした pipeline にだけ
割り当てられます。matcher は regex 配列のみを受け付けます。内部では `|` で
結合した 1 つの `RegExp` として扱います。

既定の pipeline は次のとおりです。

- Markdown: `markdownlint-cli2 --fix` → 再lint
- JSON/JSONC: `Biome check --write` → 再check
- JS/TS 系
  - 実行順: `Biome check --write` → `Oxlint --fix` → `Biome check --write` → 再check
- YAML: bundled control-plane toolchain の `yamllint`。yamllint 標準の
  config discovery を使い、config が無い repo では yamllint defaults で実行する。
- Python: `ruff format` → `ruff check --fix` → `ruff format` → `ruff check`
- Rust: bundled `control-plane-rust.sh` helper で各 crate に
  `fmt` / `clippy --fix` / `clippy -D warnings`
- Dockerfile: `hadolint`

自動修正で解決した内容は表示しません。fix 後も残った違反だけを表示します。
一方で Job 実行や hook 基盤の失敗は unresolved issues と混ぜず、runtime failure
として分離表示し、その場で pipeline を止めます。

各 step はローカル CLI を優先します。必要なら別ツールや `npx` 実行へ順に fallback
できます。たとえば JS/TS lint は `oxlint -> eslint -> eslint-npx -> oxlint-npx`
の順で試せます。ESLint 系は repo root に `eslint.config.*` があるときだけ候補に入ります。
