# Orchestrator 要件定義書

このページは、Kubernetes 専用の Orchestrator 機能の要件定義書です。基本設計は `docs/reference/orchestrator-basic-design.md`、画面設計は `docs/reference/orchestrator-screen-design.md` を参照してください。

## 1. 背景

既存リポジトリは、Control Plane / Execution Plane の 2 層構成、Kubernetes Job による短命実行、RWX PVC による Copilot session 永続化、SSH/SFTP + `rclone` による file transfer を前提にしています。

今回追加したいのは、これらの実行基盤を Web アプリケーションから扱えるようにする Orchestrator 機能です。利用者は ID とパスワードで認証した Web フロントエンドから git リポジトリに対応した workspace を作成し、その workspace に対して prompt を実行します。

## 2. 目的

- 認証済みユーザーがブラウザから workspace を作成できること
- ユーザーごとに GitHub、GitHub Copilot、Docker、SSH 公開鍵の認証情報を保存し、実行時に利用できること
- workspace ごとに Copilot session を作成し、prompt 実行後は必ず停止できること
- 続きの作業が必要な場合に、停止済み session を `resume` して再開できること
- 必要時だけ workspace 用 SSH endpoint を払い出し、不要時は速やかに解放できること
- `ClusterIP` の SSH endpoint では、画面上から端末ログインできること
- 既存の Kubernetes / PVC / SSH パターンを崩さずに実装できること

## 3. 対象範囲

本機能の対象は次のとおりです。

- ID/パスワードベースの認証付き Web フロントエンド
- ユーザーアカウント管理とユーザー単位の資格情報管理
- git リポジトリ URL を入力して workspace を作成する機能
- workspace 単位の session 作成、prompt 実行、結果参照、resume
- prompt 実行時に起動する短命の ACP runner Job
- workspace に対する任意の SSH endpoint 発行
- `ClusterIP` endpoint に対するブラウザ端末ログイン
- Kubernetes 上の状態管理、監査、クリーンアップ

次は対象外とします。

- 非 Kubernetes 環境への対応
- OIDC / SAML / 公開 self-sign-up
- 常時起動の Copilot runner
- 1 workspace での複数同時 session 実行
- GUI ベースの Git merge / rebase 解決
- PR 作成やレビュー自動化そのもの

## 4. 利用者像

### 4.1 エンドユーザー

- Web フロントエンドへログインし、workspace を作成する
- workspace に対して prompt を送る
- 実行結果、履歴、最新 session 状態を確認する
- 必要時だけ SSH endpoint を発行して workspace を調査する

### 4.2 オペレーター

- ユーザーアカウントの作成、無効化、初期パスワード再発行を行う
- platform policy として `LoadBalancer` 利用可否、password policy、quota を管理する
- namespace、StorageClass、ResourceQuota、NetworkPolicy を管理する
- 失敗した Job や SSH endpoint の監査と回収を行う

## 5. 業務要件

### 5.1 ユーザーアカウントと資格情報

- アプリはローカル ID/パスワード認証を提供し、OIDC は本スコープに含めない
- 初期導入では公開 self-sign-up を行わず、管理者によるユーザー作成を前提にする
- ユーザーは初回ログイン後に自分のパスワードを変更できる
- パスワードは平文保存せず、強いハッシュで保存する
- ユーザーは自分の GitHub 認証情報、GitHub Copilot 認証情報、Docker 認証情報、SSH 公開鍵を画面から登録・更新・削除できる
- 保存された資格情報はユーザーごとに分離され、別ユーザーの workspace や execution へ暗黙に共有しない

### 5.2 workspace 作成

- ユーザーは git リポジトリ URL、対象 branch または revision、workspace 名を指定できる
- private repository を扱うため、workspace 作成時は要求ユーザーの保存済み GitHub 認証情報を使える
- workspace 作成時、システムは Kubernetes 上に workspace 用 PVC を用意し、初期 clone を実行する
- clone 完了後、workspace は `Ready` になり、以降の prompt 実行対象になる
- 初期 clone に失敗した場合、workspace は `Error` となり、失敗ログを保持したまま再試行を待つ
- 初期 clone の再試行では中途半端な working tree を引き継がず、workspace PVC を再作成してから clone をやり直す

### 5.3 prompt 実行

- ユーザーは workspace を選び、prompt を送信できる
- 初回実行時、システムは session を新規作成する
- 2 回目以降の実行時、ユーザーは既存 session を `resume` できる
- 実行中は進行状況、標準出力、最終要約、失敗理由を UI から確認できる
- 同一 workspace ですでに `Queued` または `Running` の execution がある場合、新規 prompt は受け付けず `409 Conflict` を返す

### 5.4 session ライフサイクル

- session は workspace 単位で 1 つだけ active にする
- session 状態は `Pending -> Idle -> Running -> Idle|Error|Archived` を基本遷移とする
- prompt 処理が完了したら runner は必ず終了し、idle Pod を残さない
- runner 終了前に session state、実行ログ、要約、メタデータを永続化する
- `resume` 時は永続化済み state を再マウントし、同一 session として処理を継続する
- resume に失敗した場合は明示的に `Error` とし、暗黙に新規 session へ切り替えない
- 新しい session を開始する場合だけ、既存 session を明示的に `Archived` へ遷移させて置き換える
- `Error` または `Archived` の session は自動復旧せず、ユーザーまたはオペレーターの明示操作でのみ新規 session へ切り替える
- session state が欠損または破損している場合、resume は `Error` で停止し、既存 artifact を残したまま調査可能にする

### 5.5 Copilot 連携

- アプリケーションと Copilot の通信は ACP で行う
- ACP 接続は runner Job 内で確立し、Web フロントエンドは ACP を直接扱わない
- prompt 実行に必要な GitHub / Copilot / Docker の認証情報は、要求ユーザーに紐づく Kubernetes Secret から注入する

### 5.6 SSH endpoint とブラウザ端末

- ユーザーが明示的に要求した場合のみ、workspace 用の SSH container を新規起動する
- SSH endpoint ごとに Kubernetes Service を作成する
- SSH endpoint は workspace の同じ PVC を mount し、作業内容を prompt 実行と共有する
- SSH endpoint には TTL を持たせ、期限切れまたは利用終了時に Pod / Service を削除する
- SSH endpoint の Service type は既定で `ClusterIP` とし、`LoadBalancer` は管理者ポリシーで許可された場合だけ選択できる
- `ClusterIP` を選んだ場合は、画面上から端末ログインできる機能を同時に提供する
- `ClusterIP` のブラウザ端末ログインでは、システムが内部生成した一時 SSH 鍵を使い、ユーザー入力の公開鍵を必須にしない
- `LoadBalancer` を選んだ場合は、ユーザーが保存した SSH 公開鍵を使って直接 SSH 接続できる
- `LoadBalancer` を作成した場合は、要求者、時刻、workspace、公開先を監査ログへ残す

## 6. 機能要件

### 6.1 認証・認可

- Web フロントエンドはログイン ID とパスワードで認証した session が無い限り、workspace 一覧や実行結果を表示してはならない
- ユーザーは自分に割り当てられた workspace だけを参照・操作できる
- ユーザーは自分の資格情報だけを参照・更新できる
- 管理者だけがユーザー管理、cluster-wide の設定、監査情報へアクセスできる

### 6.2 状態管理

- workspace、session、execution、ssh endpoint の状態は Kubernetes 上へ永続化する
- 状態遷移は API と controller のどちらから見ても一貫していなければならない
- UI は watch または polling で状態変化を追従できる
- API は workspace ごとの active execution 制約を検証し、controller は同じ制約を最終防衛線として再検証する

### 6.3 実行履歴

- ユーザーは過去の prompt、開始時刻、終了時刻、終了理由、要約を参照できる
- 失敗した execution については失敗フェーズと主要ログ断片を参照できる

### 6.4 クリーンアップ

- 完了した runner Job は結果永続化後に削除できること
- 成功した runner Job と provisioner Job は短い TTL で回収し、失敗した Job は調査用に一定期間保持すること
- 期限切れ session と execution artifact は保持期間に従って回収できること
- SSH endpoint は TTL 到達時に自動削除されること
- SSH endpoint の削除は `Service -> Pod -> Secret` の順で行い、新規接続停止を先に反映すること

### 6.5 ユーザー管理と資格情報管理

- 管理者はユーザーの作成、無効化、初期パスワード再発行、ロール変更を行えること
- ユーザーは自分の GitHub / Copilot / Docker / SSH 公開鍵を保存、更新、削除できること
- 資格情報が未設定または不正な場合、workspace 作成や execution は明示的なエラーで停止すること
- execution と SSH endpoint は要求ユーザーの資格情報だけを参照すること

### 6.6 ブラウザ端末

- `ClusterIP` の SSH endpoint が `Ready` のとき、ユーザーは UI からブラウザ端末を開始できること
- ブラウザ端末は内部生成した一時 SSH 鍵と WebSocket bridge を用いて cluster 内の SSH Service へ接続すること
- ブラウザ端末終了時、一時鍵と terminal session は回収されること

### 6.7 Kubernetes 接続保証

- API と controller は Kubernetes へ接続できない場合に `Ready` になってはならない
- Kubernetes 接続が確立できない間、書き込み系 API は `503 Service Unavailable` を返す
- UI は cluster 未接続時に変更操作を無効化し、障害バナーを表示する

## 7. 非機能要件

### 7.1 Kubernetes 専用

- 本機能は Kubernetes のみを対象とする
- 実行、永続化、サービス公開、監査は Kubernetes の標準リソースを前提にする
- in-cluster config または明示的な Kubernetes 接続設定が取得できない場合、本機能は hard-fail する

### 7.2 セキュリティ

- Secret は UI や API レスポンスへ平文で返さない
- パスワードはハッシュのみを保存し、平文を再表示しない
- GitHub credential、Copilot credential、Docker credential、SSH 公開鍵はユーザーごとの Kubernetes Secret で管理する
- SSH endpoint は利用者単位に鍵を分離し、不要時に失効させる
- ブラウザ端末用の内部生成 SSH 鍵は短命とし、UI へ秘密鍵を開示しない
- NetworkPolicy で runner / SSH Pod の到達先を最小化する

### 7.3 リソース効率

- prompt 完了後に runner を残さない
- SSH endpoint は要求されたときだけ起動する
- workspace PVC は永続化し、session / log / artifact は workspace ごとの RWX 領域へ分離する

### 7.4 可観測性

- Workspace / Session / Execution / SSH Endpoint の phase を Kubernetes status と UI の双方で確認できる
- 主要なライフサイクルイベントは監査ログとして残す
- 実行失敗時に原因の切り分けに必要なログ断片を保持する

### 7.5 信頼性

- controller は再実行しても安全な idempotent 動作を持つ
- runner 再起動や controller 再起動後も永続化済み session state から復旧できる

## 8. 前提と制約

- 既存リポジトリの `control-plane-run` / `k8s-job-run` 相当の Kubernetes Job 実行パターンを再利用する
- session state は既存の `~/.copilot/session-state` と同様に RWX PVC へ置く
- file handoff が必要な経路は既存の SSH/SFTP + `rclone` パターンを優先する
- Web アプリケーションから直接 container shell を長時間保持しない
- multi-tenant 前提のため、workspace ごとに namespace、RBAC、NetworkPolicy、PVC を分離する

## 9. 受け入れ条件

- ユーザーが ID/パスワードでログインできる
- ユーザーが自分の GitHub / Copilot / Docker / SSH 公開鍵を保存できる
- 認証済みユーザーが git リポジトリから workspace を作成できる
- `Ready` workspace に対して prompt を実行し、完了後に runner が終了する
- 同じ workspace で `resume` による follow-up prompt が成功する
- `ClusterIP` endpoint に対してブラウザ端末ログインできる
- SSH endpoint 要求時に新規 Pod と Service が作成され、解除時に削除される
- 失敗時に UI と Kubernetes status の両方で失敗理由を追跡できる
