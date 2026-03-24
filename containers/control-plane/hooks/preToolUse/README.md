# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する hook です。`bash` tool で実行される Git コマンドを shell 風に分解し、宣言的な deny rule に一致したものを `permissionDecision: "deny"` で拒否します。

## Config

bundled rule は `deny-rules.json` で管理します。`preToolUse` は高頻度で走るため、このリポジトリの既存 hook config (`hooks.json`, `linters.json`) と同じく JSON に寄せ、追加の YAML parser を毎回起動しないようにしています。

対象 repo では任意で `.github/pre-tool-use-rules.json` を置くと、bundled rule に追加できます。bundled rule と同じ `id` は使えず、使った場合は config error として明示的に拒否します。

```json
{
  "rules": [
    {
      "id": "repo-block-status",
      "toolNames": ["bash"],
      "match": {
        "kind": "gitCli",
        "subcommand": "status"
      },
      "reason": "repo-local policy"
    }
  ]
}
```

## Matching model

grep 的な生文字列一致ではなく、`bash` command を token 化して `git <subcommand> <args...>` を抽出してから評価します。これにより `FOO=1 git push --force`, `git -C repo push -f`, `cmd1 && git commit --no-verify` のような形も、単純な substring より安全に扱えます。deny rule 判定では subcommand 後の `--` 以降を option とみなさないため、pathspec や ref 名が偶然フラグ文字列を含んでも誤検知しません。
