# Fork からの変更点

[openai/symphony](https://github.com/openai/symphony) の fork。upstream の `58cf97d` 時点を起点として以下を追加している。

## リポジトリ参照

- workspace `after_create` フックを `muraikenta/symphony` から clone するよう変更
- `mix workspace.before_remove` のデフォルトリポジトリを `muraikenta/symphony` に
- `elixir/README.md` の clone 手順も同 fork を指すように更新

## Linear 連携

- **チーム単位ポーリング**: `tracker.team_key` を追加。`project_slug` と併存可（両方ある場合は `team_key` 優先）
- **ラベルゲート**: `tracker.required_labels` を追加。設定時、issue が指定ラベルのいずれかを持つときだけ拾う（ANY-of）
- **`Human Review` → `Human PR Review` にリネーム**

## 要件未確定チケットの取り扱い

- **Step 0.5: Spec sufficiency check** 新設。`Todo` 入った時に AI が要件十分性を評価
  - 判定基準: Goal / Acceptance Criteria / Scope 境界 / ブロッキング未決事項なし
  - 不足 → description にスペック草案を直書きして `Human Spec Review` へ移動・ターン終了
  - 十分 → 既存通り `In Progress` で実装開始
- 人間が `Human Spec Review` で承認 → `Todo` に戻す → 次回ポーリングで実装が始まる
- description 編集禁止ルールに spec フェーズの例外を明記
- **Step 1.5「Classify and respond to incorporated comments」**: workpad 整合時に新規取り込んだ人間コメントを **質問・FYI・フィードバック・混在** に分類して応答方式を変える。
  - **質問**: workpad / git / PR から具体的な根拠付きで回答 → 同じチャネル（Linear or GitHub PR）に返信 → ✅ リアクション → コード変更せずに turn 終了（ステートも維持）
  - **FYI**: 👀 リアクション + workpad Notes に記録、対応不要
  - **フィードバック**: workpad に反映 → ✅ リアクション → 通常の実装フロー
  - **混在**: 質問部分は返信、指示部分は実装、リアクションは ✅ 1つ
  - これで「Linear / GitHub PR コメント上で Symphony と会話可能」になる。質問だけのコメントで毎回コード変更ループが回るのを防ぐ
- **Symphony 自身への改善要望は GitHub Issue として `muraikenta/symphony` に起票**: ワークフロー / オーケストレーター / プロンプト の不備や改善点を発見したエージェントは `gh issue create --repo muraikenta/symphony` で起票（重複は事前検索でスキップ）。製品 Linear に紛れさせず、symphony 自体の課題管理を分離。issue URL は workpad Notes に追記
- **ワークスペースフックに Symphony 環境変数を露出**: `after_create` / `before_remove` の `sh -lc` 実行時、以下の env vars を自動セット
  - `SYMPHONY_WORKFLOW_FILE` — workflow ファイルの絶対パス
  - `SYMPHONY_WORKFLOW_DIR` — `dirname` 結果（リポジトリ内の固定相対位置を起点にできる）
  - `SYMPHONY_WORKSPACE_DIR` — 現在のワークスペース絶対パス
  - `SYMPHONY_ISSUE_IDENTIFIER` — Linear チケット識別子
  - 用途例: 個人ローカルパスをハードコードせず、`"$SYMPHONY_WORKFLOW_DIR/.."` から secrets ファイル（`.env` 等）をコピーする after_create フック。SSH worker 経由でも同じ env vars が prelude として転送される
- **PR の人間からのフィードバックを検知して自動で Todo に戻す PrReviewMonitor**: `tracker.github_repo` が設定されている場合、専用 GenServer が定期的（デフォルト 30 秒）に `Human PR Review` ステートのチケットの GitHub PR を走査。検知対象は `CHANGES_REQUESTED` レビュー、トップレベル PR コメント、インラインレビューコメントの 3 種で、いずれも author が `[bot]` で終わるアカウント（例: `coderabbitai[bot]`、`codecov[bot]`）は除外。新しい人間アクションが見つかったらチケットを `Todo`（`tracker.pr_review_changes_requested_target_state` で変更可）に自動遷移し、Symphony の通常フローで PR フィードバックスイープが起動する。重複アクションは `kind:id` 形式の signal id の in-memory map で抑止。これで「自分の PR には Request changes を付けられない」GitHub の制約があっても、普通にコメントするだけで自動ルーティングが効く
- **新しい Linear コメントを検知して自動で Todo に戻す IssueCommentMonitor**: 自分で作成した PR には `Request changes` できないので（GitHub の制約）、補完として Linear の issue コメントもポーリング。`Human PR Review` 中の issue に新規コメントが付くと `Todo` に自動遷移。Codex Workpad コメント、bot サマリー（`🐶 みらいいぬ自動調査` 等）、スレッド返信は対象外。issue 初回観測時はその時点の最新コメントをベースラインとして記録し、以降に追加された人間コメントだけがトリガー
- **Linear の `branchName` を NFC 正規化**: Linear API は branch 名を NFD（分解形）で返すことがある（例: `デ` を `テ` + 結合濁点で表現）。Git の ref は NFC で保存されるため、未正規化のまま `gh pr list --head ...` に渡すとマッチしない。`Linear.Client.normalize_issue` で NFC に正規化してから `Issue` 構造体に格納するよう修正

## ステート遷移

- マージ完了後の遷移先を `Done` → `QA` に変更（QA チームが検証して `Done` へ手動遷移する運用）
- `terminal_states` に `QA` 追加（エージェントは触らない）
- 環境/権限不足でエージェントが詰まった時の専用ステート `Blocked` を追加。`Human PR Review`（PR レビュー待ち）と意味が混ざらないよう分離。`Blocked` も `terminal_states` に含める（人間が原因解決して `Todo` に戻すと再開）

## テスト安定化

- リトライ遅延テスト 3件の flake を修正（アサーション時刻ではなく送信前 anchor を基準に判定）
- SSH trace 待機タイムアウトを 500ms → 5s に拡張

## 現行 WORKFLOW.md 構成（参考）

- team: `GIKAI`、拾うラベル: `ai-task`
- active states: `Todo`, `In Progress`, `Merging`, `Rework`
- terminal states: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Blocked`, `QA`, `Done`

## 必要な Linear 側セットアップ

- ステート追加: `Human Spec Review`、`Human PR Review`（既存 `Human Review` をリネーム）、`Blocked`、`QA`
- ラベル: `ai-task`（または WORKFLOW.md の `required_labels` で指定した名前）
