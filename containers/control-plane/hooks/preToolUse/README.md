# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する
Rust hook です。hook binary と `LD_PRELOAD` exec policy library は、同じ Rust
engine と YAML rule を共有します。`node` や shell script 経由の実プロセス実行も
含めて、一貫した deny 判定をします。

## Config

bundled rule は `deny-rules.yaml` で管理します。schema は
`commandRules`、`protectedEnvironments`、`fileAccessRules` の 3 本立てです。
command 側は `rule` に 1 本の正規表現を書きます。engine は normalized token
stream を `\0` 区切りで連結して、この regex に当てます。順序・隣接・cluster
などの条件は YAML 側で表現できます。

対象 repo では任意で `.github/pre-tool-use-rules.yaml` を置くと、bundled rule に追加できます。

```yaml
commandRules:
  - rule: 'git(?:\x00[^\x00]+)*\x00status(?:\x00[^\x00]+)*\x00--short(?:\x00[^\x00]+)*'
    reason: repo-local policy
fileAccessRules:
  - path: ${HOME}/.config/gh/hosts.yml
    reason: gh only
    allowedExecutables:
      - /usr/bin/gh
```

## Matching model

`bash.command` は生文字列 grep ではありません。shell 風 token 化と command
chain 分割をします。`sh -c` / `bash -lc` unwrap と、環境変数 prefix 解析も
行います。評価対象は `basename` と argv token 全体を並べた normalized token
stream です。各 token は `\0` で結合します。`rule` は内部で `^(?:<pattern>)$`
に包んで full match します。`git(?:\x00[^\x00]+)*\x00commit...` のように、
basename・順序・隣接を 1 本の regex で書けます。engine 側は option ごとの
value 知識を持ちません。`-[A-Za-z0-9]*n[A-Za-z0-9]*` のような pattern を
置けば、short option cluster もまとめて deny できます。

`protectedEnvironments` は command rule とは独立した global deny list です。
exec 側では、親プロセス環境との差分だけを override とみなします。control
plane が管理する既定の `GIT_CONFIG_GLOBAL` はそのまま通します。上書き・追加・
unset は拒否できます。`git push --force-with-lease` は引き続き許可します。

`fileAccessRules` は exact path ベースの read blocker です。`${VAR}` 展開後の
path が空なら、その rule 自体を無効化します。候補 path は canonical path まで
展開します。directory path を rule に置くと、その配下もまとめて保護できます。
`allowedExecutables` も absolute path 必須です。exec 側は実行中 binary の実
path を照合します。`bash /usr/local/bin/control-plane-copilot` のような shell
wrapper では、script path 自体も照合します。basename-only allowlist は受け付け
ません。`/usr/local/bin/control-plane-copilot` や `/usr/bin/gh` のように、
managed executable の full path を明示してください。

`/run/control-plane-auth` のような Secret mount は、startup 専用 input として
扱います。interactive shell からの direct read は、directory rule でその配下
ごと防ぐのが基本です。entrypoint は起動時にそれらを `authorized_keys`、
`~/.config/gh/hosts.yml`、private runtime token file のような managed surface
へ移します。そのあと user-facing process は、そちらだけを使います。
