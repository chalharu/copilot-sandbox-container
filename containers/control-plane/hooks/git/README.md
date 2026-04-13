# global git hooks

Control Plane entrypoint は bundled Git hook を root-owned な
`/usr/local/share/control-plane/hooks/git/` から提供します。root-owned な
`GIT_CONFIG_GLOBAL` からも提供します。`~/.gitconfig` は互換用 symlink として
残します。bundled Copilot hook も root-owned な `COPILOT_HOME/hooks/` から
参照します。`~/.copilot/hooks/` は互換用 symlink にとどめます。親の
`~/.copilot/` は sticky directory にして、user からの差し替えを防ぎます。
これにより、Control Plane 内の全リポジトリで共通の Git hook を自動的に使えます。

`pre-commit` は `main` / `master` への commit を拒否します。feature branch
では bundled `postToolUse` linter
(`${COPILOT_HOME:-$HOME/.copilot}/hooks/postToolUse/main`) を JSON stdin 付きで
起動します。その後、repo root に executable な `.github/git-hooks/pre-commit`
があれば続けて実行します。どちらかが失敗したら commit を止めます。

`pre-push` は Git が渡す stdin を調べて、`refs/heads/main` /
`refs/heads/master` への push を拒否します。保護対象でない push では、
executable な `.github/git-hooks/pre-push` があれば、元の引数と stdin を
そのまま引き継いで実行します。

repo ごとの hook は tracked file として管理できるように `.github/git-hooks/` 配下へ置きます。hook file が存在しても regular file でない、または executable でない場合は明示的に失敗させます。
