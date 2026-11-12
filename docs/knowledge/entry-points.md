# 機能別の探索入口

2026-11-12: パスの存在を確認。まずファイル名・シンボルを検索し、関係する箇所だけ読む。

| 責務 | 入口（プロジェクトルート基準） |
|---|---|
| 一覧・グリッド | `lib/scene/gridGallery.dart` |
| 詳細・個別表示 | `lib/scene/detailImage.dart` |
| タグ保存・取得・検索 | `lib/database/tag_service.dart` |
| ローカル・Windows取得 | `lib/repository/folderRepository.dart` |
| Android SAF取得 | `lib/repository/android_folder_repository.dart` |
| サーバーメタデータ | `server/services/metadata_store.py` |
| Web APIクライアント | `lib/web/web_remote_api_client.dart` |
| ローカルDB | `lib/database/app_db.dart` |
| ホストDB | `server/repositories/sqlite_store.py` |

旧AGENTSの `androidFolderRepository.dart`、`services/metadata_store.py`、`web/web_remote_api_client.dart` は上記へ訂正。APIクライアントの責務をサーバー起動だけに限定しない。

例: `rg --files lib/repository -g '*android*'` → `rg -n '対象シンボル' 対象ファイル` → 必要な周辺行・直接依存。生成物・監査ログ・秘密情報ファイルを広域検索へ無条件に含めない。
