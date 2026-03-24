# preToolUse policy hook

Copilot CLI の `preToolUse` hook で、bundled な禁止コマンドポリシーを適用する hook です。`bash` tool で実行される Git コマンドを shell 風に分解し、宣言的な deny rule に一致したものを `permissionDecision: "deny"` で拒否します。

## Config

bundled rule は `deny-rules.yaml` で管理します。loader には `js-yaml` を使い、schema 自体は `toolName` / `column` を group の上位に寄せた compact 形式にしています。

対象 repo では任意で `.github/pre-tool-use-rules.yaml` を置くと、bundled rule に追加できます。

```yaml
- toolName: bash
  column: command
  patterns:
    - patterns:
        - '^git status(?: .+)? --short(?: |$)'
      reason: repo-local policy
```

## Matching model

pattern 自体は grep/regex 風ですが、`bash` の `command` はそのまま生文字列に対して評価しません。まず shell 風に token 化して command chain を分割し、Git command はさらに `git <subcommand> <normalized-args...>` へ正規化してから pattern を当てます。

これにより `FOO=1 git push --force`, `git -C repo push -f`, `cmd1 && git commit --no-verify` に加えて `sh -c 'git push -f'` や `bash -lc "git commit --no-verify"` のような wrapper 経由も扱えます。`git commit -m "-n"` や subcommand 後の `--` 以降の token では誤検知せず、`git push --force-with-lease` は bundled policy では許可します。
