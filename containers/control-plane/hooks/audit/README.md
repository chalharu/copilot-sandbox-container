# audit hook

Copilot CLI の `sessionStart` / `userPromptSubmitted` / `preToolUse` / `postToolUse` hook を、SQLite ベースの監査ログへ保存するための bundled hook です。

## Copilot hooks

Control Plane entrypoint は bundled hook JSON を root-owned な `COPILOT_HOME/hooks/` から読み、互換用に `~/.copilot/hooks/` symlink も張ります。`hooks.json` は `COPILOT_HOME` を優先して `hooks/audit/main` を起動するため、repo ごとの `.github/hooks/` を置かなくても、共通の監査ログ hook を保護された path から利用できます。

監査ログは `~/.copilot/session-state/audit/audit-log.db` に保存されます。`sessionStart` では repo root と git remotes を含むプロジェクトコンテキストを記録し、`userPromptSubmitted` ではユーザープロンプト、`preToolUse` / `postToolUse` ではツール名・引数・結果を保存します。各 row は hook プロセスの親プロセス ID を表す `ppid` を持ち、SQLite 上の親子参照としては扱いません。

保持上限は `CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS` で調整します。tool hook 実行後にレコード数がこの上限を超えていた場合は、古いレコードから削除して、おおむね上限の 3/4 件まで戻します。これにより最新側の履歴を残しつつ、保持件数を明示的に制御できます。`ppid` は OS のプロセス情報なので、prune で残った row に dangling な値があってもそのまま保持します。
