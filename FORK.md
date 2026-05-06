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

## ステート遷移

- マージ完了後の遷移先を `Done` → `QA` に変更（QA チームが検証して `Done` へ手動遷移する運用）
- `terminal_states` に `QA` 追加（エージェントは触らない）

## テスト安定化

- リトライ遅延テスト 3件の flake を修正（アサーション時刻ではなく送信前 anchor を基準に判定）
- SSH trace 待機タイムアウトを 500ms → 5s に拡張

## 現行 WORKFLOW.md 構成（参考）

- team: `GIKAI`、拾うラベル: `ai-task`
- active states: `Todo`, `In Progress`, `Merging`, `Rework`
- terminal states: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `QA`, `Done`

## 必要な Linear 側セットアップ

- ステート追加: `Human Spec Review`、`Human PR Review`（既存 `Human Review` をリネーム）、`QA`
- ラベル: `ai-task`（または WORKFLOW.md の `required_labels` で指定した名前）
