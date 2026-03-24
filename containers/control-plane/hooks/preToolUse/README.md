# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する hook です。`bash` tool で実行される Git コマンドを shell 風に分解し、宣言的な deny rule に一致したものを `permissionDecision: "deny"` で拒否します。

## Config

bundled rule は `deny-rules.json` で管理します。`preToolUse` は高頻度で走るため、このリポジトリの既存 hook config (`hooks.json`, `linters.json`) と同じく JSON に寄せ、追加の YAML parser を毎回起動しないようにしています。

schema は `toolName` / `column` を group の上位に寄せた compact 形式です。対象 repo では任意で `.github/pre-tool-use-rules.json` を置くと、bundled rule に追加できます。

```json
[
  {
    "toolName": "bash",
    "column": "command",
    "patterns": [
      {
        "patterns": [
          "^git status(?: .+)? --short(?: |$)"
        ],
        "reason": "repo-local policy"
      }
    ]
  }
]
```

## Matching model

pattern 自体は grep/regex 風ですが、`bash` の `command` はそのまま生文字列に対して評価しません。まず shell 風に token 化して command chain を分割し、Git command はさらに `git <subcommand> <normalized-args...>` へ正規化してから pattern を当てます。

これにより `FOO=1 git push --force`, `git -C repo push -f`, `cmd1 && git commit --no-verify` のような形も素直に表現でき、`git commit -m "-n"` や subcommand 後の `--` 以降の token では誤検知しません。
