# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する Rust hook です。hook binary と `LD_PRELOAD` exec policy library は同じ Rust engine と同じ YAML rule を共有し、`node` や shell script 経由の実プロセス実行も含めて一貫した deny 判定を行います。

## Config

bundled rule は `deny-rules.yaml` で管理します。schema は `commandRules` / `protectedEnvironments` / `optionsWithValue` の 3 本立てで、command 側は basename を先頭に置いた短い rule 配列だけを書けばよい形です。`optionsWithValue` は「この option の直後または `=` 以降は値」と扱う token を設定側で宣言するための配列です。

対象 repo では任意で `.github/pre-tool-use-rules.yaml` を置くと、bundled rule に追加できます。

```yaml
commandRules:
  - rule:
      - git
      - status
      - --short
    reason: repo-local policy
```

## Matching model

`bash.command` は生文字列 grep ではなく、shell 風 token 化と command chain 分割、`sh -c` / `bash -lc` unwrap、環境変数 prefix 解析を行ったうえで評価します。`rule` の各要素は内部で `^(?:<pattern>)$` に包まれ、先頭要素は basename、2 個目以降の非 option token は command prefix、option token は位置に依らない必須 flag として扱います。option token は raw token 優先で扱うので、clustered short option を拾いたい場合は `--no-verify|-n|-[^-]*n[^-]*` のように設定側で表現できます。一方で `git commit -m "-n"` や `git commit -mn` のような値部分は、`optionsWithValue` に列挙された option を使って parser が保守的に除外します。加えて value を取る option には `--option-value=<option>=<value>` token も付くため、`-c core.hooksPath=...` のような危険な値は主に deny rule 側の regex で塞げます。

`protectedEnvironments` は command rule とは独立した global deny list です。exec 側では親プロセス環境との差分だけを override とみなすため、control plane が管理する既定の `GIT_CONFIG_GLOBAL` はそのまま通しつつ、上書き・追加・unset は拒否できます。`git push --force-with-lease` は引き続き許可します。
