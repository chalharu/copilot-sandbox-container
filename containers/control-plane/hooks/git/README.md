# global git hooks

Control Plane entrypoint は `containers/control-plane/hooks/git/` を `~/.copilot/hooks/git/` へ同期し、`/home/copilot/.gitconfig` の `core.hooksPath` をその directory へ向けます。これにより、Control Plane 内の全リポジトリで共通の Git hook を自動的に使えます。

`pre-commit` は `main` / `master` への commit を拒否し、feature branch では bundled `postToolUse` linter (`~/.copilot/hooks/postToolUse/main.mjs`) を JSON stdin 付きで起動します。その後、repo root に executable な `.github/git-hooks/pre-commit` があれば続けて実行し、どちらかが失敗したら commit を止めます。

`pre-push` は Git が渡す stdin を調べて `refs/heads/main` / `refs/heads/master` への push を拒否します。保護対象でない push では、executable な `.github/git-hooks/pre-push` があれば元の引数と stdin をそのまま引き継いで実行します。

repo ごとの hook は tracked file として管理できるように `.github/git-hooks/` 配下へ置きます。hook file が存在しても regular file でない、または executable でない場合は明示的に失敗させます。
