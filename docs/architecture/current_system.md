# 現行システム調査（Phase 0）

対象は feature_hitomi の作業ツリー。開始時に未コミット差分はなかった。以下はソース上の確認で、実機での動作確認範囲は test_strategy.md に分けた。

## 実行環境と入口
- pubspec.yaml は 1.0.231+241、Dart 制約 ^3.10.1。調査開始時の .dart_tool/package_config.json は Flutter 3.41.5、生成に使用した Dart 3.11.3。
- lib/main.dart から lib/app のプラットフォーム別 bootstrap に進む。ネイティブは AppDb → TagService → createRepository の順で初期化し、MaterialApp の home に GalleryGridPage を渡す。Web は lib/web/web_remote_viewer_page.dart の専用画面と API クライアントを使う。
- 主画面は StatefulWidget と setState、詳細・一覧間は Navigator。lib/xviewer は Riverpod、go_router、Hive、Dio、secure storage を使う別の機能群。状態管理をアプリ全体で統一する前提は置かない。
- lib/scene は画面、lib/repository はファイルとリモート取得、lib/database は Drift とタグ・PDF出力、lib/services は設定・通信・キャッシュ。android の Kotlin は URI 権限等、windows はネイティブランナー。server/api・services・repositories に既存ホストがある。
- ビルドは pubspec.yaml を確認したルートで Windows は `flutter build windows --release`、Web は `flutter build web`。tool/host_auto_update.ps1 にはビルド以外の更新処理もある。調査用には起動しない。

## 利用者の操作と実装
| 操作 | 確認した実装 |
|---|---|
| Home・保管庫・作者一覧・フォルダ階層から詳細へ | gridGallery.dart、gallery_home_view.dart、artistTagIndex.dart、detailImage.dart。保管庫には既存のフォルダ別名と整理処理がある |
| 再帰列挙・読込進捗・ページ表示 | folderRepository.dart と android_folder_repository.dart。Windows は Directory.list、Android は SAF のほか通常パスも扱う。ローカルRepositoryに常時監視による更新は確認できず、Android はフォルダ索引10分・浅い一覧15秒の TTL を持つ |
| 画像・PDF閲覧 | reader_view.dart の Image.memory。原画像のバイト取得経路とサムネイル取得経路がある。PDF は pdfx の文書を開いてページを描画し、PdfDocumentCache が利用中の文書の破棄を調整。SAF の PDF にはキャッシュファイルを開く経路がある |
| グリッド・サムネイル | gridGallery.dart のページサイズ20、メディアサムネイル幅160、240件／32 MiB、フォルダプレビュー120件／24 MiB。RemoteMediaRepository は同時取得をまとめ、ディスク上のサムネイル320件、プレビュー96件を目安に整理 |
| タグと横断検索 | TagService と LocalTagStore が登録・削除・一括付与・作者／シリーズ検索・ホストミラーを担当。gallery_search.dart と gallery_grid_view.dart で Home／一覧検索を扱い、一覧では空白区切りの全条件、カテゴリ指定 key:value、#tag、未分類を判定 |
| 複数選択・整理・改名・PDF出力 | ギャラリーの選択状態からタグ／ファイル操作へ進む。LocalTagStore は改名に伴う関連ID更新を持つ。PdfExportService は pdf・image で生成し、通常パスと SAF の保存先を扱う |
| Android と Windows | Android は docman、MainActivity の永続 URI 権限、renameTo と失敗時処理。Windows は file_selector、dart:io、LocalPathOperationService を使用 |
| リモート | standalone／host／client が既に存在。repositoryFactory.dart がローカル実装を SwitchingMediaRepository に渡す。Web の入口は別。既存 FastAPI はメディア配信、検索、タグ、お気に入り・評価、索引、サムネイル等を提供。起動時の再スキャンは設定と対象ルートに依存 |

ローカル／ホストのテーブル・保存場所は database_migration_plan.md、負荷・認証上の具体的な差異は compatibility_risks.md を参照。
