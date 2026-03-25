# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する Rust hook です。hook binary と `LD_PRELOAD` exec policy library は同じ Rust engine と同じ YAML rule を共有し、`node` や shell script 経由の実プロセス実行も含めて一貫した deny 判定を行います。

## Config

bundled rule は `deny-rules.yaml` で管理します。schema は `commandRules` と `protectedEnvironments` の 2 本立てで、command 側は `rule` に 1 本の正規表現を書きます。engine は normalized token stream を `\0` 区切りで連結してこの regex に当てるので、順序・隣接・cluster などの条件は YAML 側で表現できます。

対象 repo では任意で `.github/pre-tool-use-rules.yaml` を置くと、bundled rule に追加できます。

```yaml
commandRules:
  - rule: 'git(?:\x00[^\x00]+)*\x00status(?:\x00[^\x00]+)*\x00--short(?:\x00[^\x00]+)*'
    reason: repo-local policy
```

## Matching model

`bash.command` は生文字列 grep ではなく、shell 風 token 化と command chain 分割、`sh -c` / `bash -lc` unwrap、環境変数 prefix 解析を行ったうえで評価します。評価対象は `basename` と argv token 全体をそのまま並べた normalized token stream で、各 token は `\0` で結合されます。`rule` は内部で `^(?:<pattern>)$` に包まれて full match されるため、`git(?:\x00[^\x00]+)*\x00commit...` のように basename・順序・隣接を 1 本の regex で書けます。engine 側は option ごとの value 知識を持たないので、`-[A-Za-z0-9]*n[A-Za-z0-9]*` のような pattern を置けば short option cluster もまとめて deny できます。

`protectedEnvironments` は command rule とは独立した global deny list です。exec 側では親プロセス環境との差分だけを override とみなすため、control plane が管理する既定の `GIT_CONFIG_GLOBAL` はそのまま通しつつ、上書き・追加・unset は拒否できます。`git push --force-with-lease` は引き続き許可します。
