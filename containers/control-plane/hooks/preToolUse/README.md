# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する Rust hook です。hook binary と `LD_PRELOAD` exec policy library は同じ Rust engine と同じ YAML rule を共有し、`node` や shell script 経由の実プロセス実行も含めて一貫した deny 判定を行います。

## Config

bundled rule は `deny-rules.yaml` で管理します。schema は `commandRules` と `protectedEnvironments` の 2 本立てで、command 側は basename を先頭に置いた `rule` 配列を使います。`rule` の 2 個目以降には plain pattern に加えて `allOf` / `anyOf` / `seqOf` matcher group を置けるので、deny 条件の組み合わせや raw argv token の隣接並びを YAML 側で表現できます。

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

`bash.command` は生文字列 grep ではなく、shell 風 token 化と command chain 分割、`sh -c` / `bash -lc` unwrap、環境変数 prefix 解析を行ったうえで評価します。`rule` の各要素は内部で `^(?:<pattern>)$` に包まれ、先頭要素は basename、plain な非 option token は command prefix、plain な option token は raw option token への必須 match として扱います。matcher group では `allOf` が AND、`anyOf` が OR、`seqOf` が raw argv token への隣接 match です。engine 側は option ごとの value 知識を持たないため、`-[A-Za-z0-9]*n[A-Za-z0-9]*` のような regex を設定側で与えると short option cluster もまとめて deny できます。

`protectedEnvironments` は command rule とは独立した global deny list です。exec 側では親プロセス環境との差分だけを override とみなすため、control plane が管理する既定の `GIT_CONFIG_GLOBAL` はそのまま通しつつ、上書き・追加・unset は拒否できます。`git push --force-with-lease` は引き続き許可します。
