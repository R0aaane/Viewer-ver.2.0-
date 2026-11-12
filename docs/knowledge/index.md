# プロジェクト知識の索引

必要な項目だけ参照する。既存の `docs/` を正本として維持し、別の `knowledge/architecture/` 等への複製は作らない。確認日: 2026-11-12。

| 分類 | 資料・用途 | 状態・注意 |
|---|---|---|
| 探索 | [入口一覧](entry-points.md) | パスの存在を確認済み |
| 手順 | [作業・検証・版更新](workflow.md) | 開発作業時に参照 |
| architecture | [システム調査](../architecture/current_system.md) | Phase 0時点。版番号・キャッシュ値等を現行値と断定しない |
| architecture / API・DB | [DB境界と移行案](../architecture/database_migration_plan.md)、[API概要](../../README.md) | DB資料の「承認後の案」は確定仕様ではない。実装を確認する |
| features | [生成ライブラリ](../architecture/generated_library.md)、[接続・認証](../architecture/private_access.md)、[同期・復旧](../architecture/sync_backup_recovery.md) | 既存仕様資料。変更時は該当実装と照合 |
| features | [PDF編集](../pdf-page-edit.md)、[Web日本語フォント](../web-japanese-fonts.md) | 対象機能の作業時に参照 |
| decisions | [段階別統合案](../architecture/integration_plan.md) | 承認前の計画を含む。完了状況・承認の根拠にしない |
| issues | [互換性リスク](../architecture/compatibility_risks.md)、[Web性能調査](../web-performance-audit.md) | 調査時点の候補・課題。現在も未解決とは断定しない |
| 検証 | [既存テストの選び方](../architecture/test_strategy.md)、[3万枚実測](../performance/30000_images.md) | 過去の結果は今回の合格証拠にしない |
| 配布 | [ホスト更新](../host-release.md) | 配布を伴う。調査のために更新スクリプトを実行しない |
| archive | [旧AGENTS](archive/AGENTS.before-2026-11-12.md) | 復元用の履歴。現行指示ではなく、通常は読まない |
| 改善記録 | [最適化の分類・計測](optimization.md) | 効果測定を行う場合のみ参照 |

重要判断を記録する際は、関連資料に「状態（確定／仮説／失効）・確認日・根拠（ソース、テスト、承認）・適用範囲」を付ける。必要になった分類のみ追加し、全履歴の移行や秘密情報の複製をしない。今回、既存機能の仕様全体を再検証したわけではない。
