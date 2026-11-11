# 検証範囲と合格条件

## Phase 0
プロジェクトルートで `flutter test test/widget_test.dart` を実行し、MetadataSettings の既定値が standalone であることを確認（1件成功）。この試験は画面起動やネットワーク切断中の閲覧を含まない。実装差分のない調査のため、全件解析・Releaseビルド・データ移行は対象外。

## 既存の試験を使う順序
- ローカルのタグとパスは test/local_tag_store_organize_test.dart、test/tag_service_host_mirror_test.dart、test/services/local_path_operation_service_test.dart。コピーしたDBで登録・解除・検索・作者／シリーズ・一括付与・フォルダ移動・改名後の関連集合を比較する。
- PDF は test/pdf_export_service_test.dart、test/repository/pdf_resource_lifecycle_test.dart、integration_test/pdf_windows_test.dart。画像詳細とPDF詳細を往復し、先頭／末尾の描画、再表示、原本解放、出力ページ順を確認する。
- 通信は test/repository/remote_media_repository_test.dart、test/services/remote_media_api_client_test.dart、Web は test/web_performance_test.dart と integration_test/web_compatibility_test.dart を起点にする。サーバー停止、遅延、切替、版競合、同時要求、キャッシュ追い出しをfixtureで追加する。
- ホストは server/tests の既存メディア・検索・タグ・索引・サムネイル試験を先に実行。生成系には隔離SQLite・一時ライブラリ・模擬ComfyUIを用い、無認証／失効、パス逸脱、ハッシュ重複、生成再送、ワーカー再起動、他ジョブの取消拒否、バックアップ復元を検証する。
- Android は使い捨てのSAFツリーで選択・再起動・改名・権限取り消しを実機確認。本番ライブラリへの書き込みやスキャンは行わない。

## 性能測定
同じ端末・アプリ版・素材目録・画像寸法分布・ディスク条件で、3万件以上の合成データを使う。冷／温キャッシュを分け、初回と変更後のスキャン時間、次ページ時間、検索中央値とp95、サムネイル初表示時間、スクロールのフレーム時間、Flutter／サーバーのピークRSS、キャッシュのバイト数を記録。生成と同時アクセスはキュー投入・開始・完了時刻と並列数を記録する。速度改善と併せて件数・順序・タグ・元画像ハッシュの一致を合格条件とする。2026-11-11〜12の30,000枚実測結果と条件・未測定範囲は [性能報告](../performance/30000_images.md) を参照。
