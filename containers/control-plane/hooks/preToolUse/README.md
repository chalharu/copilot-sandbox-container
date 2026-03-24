# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する Rust hook です。hook binary と `LD_PRELOAD` exec policy library は同じ Rust engine と同じ YAML rule を共有し、`node` や shell script 経由の実プロセス実行も含めて一貫した deny 判定を行います。

## Config

bundled rule は `deny-rules.yaml` で管理します。schema は `toolName` / `column` を group の上位に寄せつつ、generic な command fact matching と protected environment rule を表現できる compact YAML です。

対象 repo では任意で `.github/pre-tool-use-rules.yaml` を置くと、bundled rule に追加できます。

```yaml
- toolName: bash
  column: command
  rules:
    - all:
        - '^basename:git$'
        - '^arg:status$'
        - '^arg:--short$'
      reason: repo-local policy
```

## Matching model

`bash.command` は生文字列 grep ではなく、shell 風 token 化と command chain 分割、`sh -c` / `bash -lc` unwrap、環境変数 prefix 解析を行ったうえで generic fact へ変換して評価します。fact は `basename:<name>`、`arg:<token>`、`command:<joined tokens>` のような形式で、rule 側は `all` / `any` の regex で宣言します。`git commit -m "-n"` のような値つき option による誤検知を避けるための option-value 判定は engine 内で処理し、YAML には持ち込みません。

さらに `protectedEnv` を使うと、特定の環境変数名と許可値を宣言的に制限できます。bundled policy では `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` などの Git config override を保護しつつ、`git push --force-with-lease` は引き続き許可します。
