# audit hook

Copilot CLI の `sessionStart` / `userPromptSubmitted` / `preToolUse` / `postToolUse` hook を、SQLite ベースの監査ログへ保存するための bundled hook です。

## Copilot hooks

Control Plane entrypoint は `containers/control-plane/hooks/` を `~/.copilot/hooks/` へ同期し、bundled hook JSON (`hooks.json`) から `~/.copilot/hooks/audit/main.mjs` を起動します。これにより repo ごとの `.github/hooks/` を置かなくても、共通の監査ログ hook を利用できます。

監査ログは `~/.copilot/session-state/audit/audit-log.db` に保存されます。`sessionStart` では repo root と git remotes を含むプロジェクトコンテキストを記録し、`userPromptSubmitted` ではユーザープロンプト、`preToolUse` / `postToolUse` ではツール名・引数・結果を保存します。

保持上限は `CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS` で調整します。tool hook 実行後にレコード数がこの上限を超えていた場合は、古いレコードから削除して、おおむね上限の 3/4 件まで戻します。これにより最新側の履歴を残しつつ、保持件数を明示的に制御できます。
