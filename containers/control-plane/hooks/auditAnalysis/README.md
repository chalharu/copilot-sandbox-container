# auditAnalysis hook

`agentStop` / `subagentStop` / `sessionEnd` / `errorOccurred` のタイミングで監査ログ SQLite DB を読み、`~/.copilot/session-state/audit/audit-analysis.db` へ異常パターンの集計結果を保存する bundled hook です。

## 役割

- `userPromptSubmitted` を元にしたユーザー指摘の検出
- 監査ログ内の `postToolUse` を元にしたエラー解決パターンの追跡
- 監査ログ内の `preToolUse` を元にした繰り返し処理の検出
- 一定量の証跡が溜まった scope に対する Agent / Command / Skill 候補の再計算

実処理は bundled skill `audit-log-analysis` の helper script (`scripts/audit-analysis.mjs`) を使っており、hook 自体はそのスクリプトを呼び出す薄い wrapper です。
