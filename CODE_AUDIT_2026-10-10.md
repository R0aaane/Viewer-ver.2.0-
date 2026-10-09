# PDFViewer コード監査・修正報告

実施日: 2026-10-09〜2026-10-10 / 対象バージョン: **1.0.206+216**

## 結論・調査範囲

PDFのデッドロック、描画中のドキュメント破棄、例外時のリソース解放漏れ、画像欠落を成功扱いするPDF出力、Webの例外処理、認証情報のログ出力を修正した。画面構成・操作方法・既存機能は変更していない。

開始時のGit作業ツリーはクリーン。既存のユーザーデータ、設定、DB、ライブラリー内のPDFは変更していない。コミット・外部公開は行っていない。

全体の構成・依存関係・参照関係・静的解析・既存テストを確認し、一覧／詳細表示、Windows・Android・リモートのPDF処理、Web API、タグ／履歴、PDF変換、Python配信サーバー、X認証の接続箇所を重点的に追跡した。生成コード・外部ライブラリーの全面改変は避けた。

これは全ソースを一行ずつ手動証明したものでも、全画面・全OSの実機検証でもない。特にズーム／スクロールの体感、巨大PDFのピークメモリ、Android SAF実機、iOS/macOS/Linuxの動作は未検証。安全性をテストで確認できる修正に限定した。

以下のファイル名はリポジトリルートからの相対パス。

## 発見事項・原因・修正

| 重要度 | 問題と原因 | 対応 |
| --- | --- | --- |
| P1 | AndroidのPDFサムネイル生成が同じ非再入ロックを二重取得し、処理が完了しない | ロック取得を呼び出し境界に集約。完了・解放の回帰テスト追加 |
| P1 | PDFを開いてから描画開始までの間や、描画待機中にLRUから破棄される。終了処理も描画完了を待たない | 共通の `PdfDocumentCache` に集約し、open〜render〜page closeまで同じ利用区間で管理。待機中・実行中のPDFを保護し、disposeは受理済み処理を待つ |
| P1 | 画像をデコードできなくてもPDF変換ワーカーが成功を返すため、ページ欠落を正常完了と誤認する | 不正画像をエラーにする。保存エラーも親Isolateへ返し、応答待ちのまま停止しないようにした |
| P1 | Webで使うPDF.js 3.11.174がCVE-2024-4367の対象。pdfxが任意の描画オプションをすべて転送するわけではない | `getDocument` の境界で `isEvalSupported=false` を強制。既存exports・戻り値・他のオプションは保持。互換性未確認のメジャー更新は行わない |
| P2 | Android／リモートで描画失敗時に `PdfPage.close()` が呼ばれない。Webではページのclose失敗でdocumentのcloseも飛ばされる | `finally`／ネストした `finally` で解放を保証 |
| P2 | 詳細画面の終了経路によって保留中の描画が残る。初回先読みを再利用してページ編集後にも古いページ数・描画結果が戻る | disposeでキャッシュ／待機描画をクリア。初回先読みは一度だけ消費し、失敗結果を再試行可能にした |
| P2 | Webの非nullableなFutureに対する後処理の `catchError` がnullを返し、元の通信エラーに加えて非同期エラーを発生させる | 後処理を `then<void>(..., onError: ...)` に変更。失敗したFutureはキャッシュから除去 |
| P2 | ダウンロード本文の受信停止にはタイムアウトがなく、書き込み側の速度制御もない。HTTPエラーでも既存の保存先を削除し得る | 本文の無通信タイムアウト、`addStream`によるバックプレッシャー、出力開始後だけの部分ファイル削除、HttpClientの確実な解放 |
| P2 | 不正なHTTP Rangeの数値変換が例外になり500を返す。空ファイル・範囲外の扱いが不適切 | 構文検証を追加。不正形式は400、満たせない範囲は416と `Content-Range: bytes */N`。有効な通常／末尾／開放範囲は維持 |
| P2 | サーバー終了時にキャッシュ中のPDFドキュメントを閉じない | ThumbnailServiceにcloseを追加し、lifespanの終了処理で実行。個別close失敗時も他のPDFとSQLiteを解放 |
| P2 | OAuthのcode/stateやコールバックURL、Bearerを含み得るリクエストヘッダーがログに出る。タイムアウト後もネイティブイベント購読が残る | 秘密値のログを除去。Stream側のtimeoutで購読を終了。非同期例外をtry内で捕捉。タイムライン用Dioも破棄時にclose |
| P3 | フォルダープレビューのnull結果をLRUで触るとキャッシュエントリーが消え、無駄な再探索になる | removeより前にキーの存在を確認し、nullのキャッシュも保持 |
| P3 | PDF管理処理が3実装に分散し、未使用ラッパー・依存ライブラリー・古いバージョンfallbackが残る | 共通化と参照確認済みの削除。native／Webのfallbackも現行バージョンに整合 |

PDF.jsの対処はMozillaが案内する回避策に基づく。脆弱性修正版への更新そのものではない。[Mozilla security advisory](https://github.com/mozilla/pdf.js/security/advisories/GHSA-wgrm-67xf-hhpq)

Range応答は標準の範囲指定と416応答を参照した。[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-range)

## 変更ファイル

### アプリケーション・サーバー

| ファイル | 内容 |
| --- | --- |
| `lib/services/pdf_document_cache.dart`（新規） | PDFの利用予約、直列化、LRU、破棄待機を共通化 |
| `lib/repository/folderRepository.dart` | Windowsのopen／render／invalidate／disposeを共通管理へ移行 |
| `lib/repository/android_folder_repository.dart` | 二重ロック解消、例外時のpage解放、共通管理、file URI対応 |
| `lib/repository/remote_media_repository.dart` | 共通管理、page解放、利用中ファイルのディスクキャッシュ保護、open失敗時だけ再ダウンロード |
| `lib/scene/detailImage.dart`, `lib/scene/detail_reader_controller.dart` | 終了時の待機描画クリア、先読みの寿命と再試行修正 |
| `lib/scene/gallery_thumbnail_cache.dart` | null結果のキャッシュ保持、不要コメント除去 |
| `lib/scene/reader_view.dart`, `lib/scene/detail_tag_panel.dart`, `lib/database/tag_service.dart` | 参照のないprivateラッパー／ヘルパー削除 |
| `lib/database/pdf_export_service.dart` | 変換失敗・保存失敗の通知、到達しないnull fallback除去 |
| `lib/services/remote_media_api_client.dart` | 本文タイムアウト、書き込み速度制御、部分ファイルとHTTP接続の解放 |
| `lib/web/pdfjs_safety.dart`（新規）, `lib/web/web_remote_api_client.dart` | PDF.js eval無効化、失敗Futureの扱い、PDF解放 |
| `lib/xviewer/services/x_auth_callback_service.dart`, `lib/xviewer/services/x_oauth_service.dart` | 認証情報のログ除去、購読終了、例外処理 |
| `lib/xviewer/features/timeline/presentation/providers/timeline_controller.dart` | ヘッダーログ抑止、Dio解放 |
| `server/services/media_stream_service.py` | Range検証・416応答 |
| `server/services/thumbnail_service.py`, `server/main.py` | 終了時のPDF／SQLite解放 |
| `pubspec.yaml`, `pubspec.lock` | バージョン更新、未使用printing削除、テストで使う既存の推移依存をdev依存として明示 |
| `lib/services/app_version_service.dart`, `lib/web/web_remote_viewer_page.dart` | native／Web fallbackバージョン更新 |
| `windows/flutter/generated_plugin_registrant.cc`, `windows/flutter/generated_plugins.cmake`, `linux/flutter/generated_plugin_registrant.cc`, `linux/flutter/generated_plugins.cmake`, `macos/Flutter/GeneratedPluginRegistrant.swift` | printing削除に伴う生成ファイル更新 |

### テスト・検証コード

- 新規: `test/support/fake_pdf.dart`, `test/services/pdf_document_cache_test.dart`, `test/repository/pdf_resource_lifecycle_test.dart`, `test/services/detail_reader_controller_test.dart`, `test/pdf_export_service_test.dart`, `test/services/x_auth_callback_service_test.dart`。
- Web新規: `test/web/pdfjs_safety_test.dart`, `tool/pdfjs_safety_smoke.dart`。
- サーバー新規: `server/tests/test_media_stream_service.py`, `server/tests/test_thumbnail_shutdown.py`。
- 拡張: `test/services/remote_media_api_client_test.dart`（停止した本文、既存保存先の保護）。
- テスト基盤／古い期待値の整合: `test/tag_service_host_mirror_test.dart`（ローカルHTTPをFlutterの400スタブに置換しない）、`test/media_file_types_test.dart`（実装済みGIF対応）、`test/services/home_activity_store_test.dart`（stable ID）、`test/repository/remote_media_repository_test.dart`（一時パス・実在するアップロード元・現在のメタデータ取得／capability契約）、`server/tests/test_routes_search.py`（設定ルート外を返さない既存仕様）。
- 日本語の既存期待文字列は変更していない。残る不一致は後述。

## 削除・整理と性能面

- 3リポジトリに重複していたPDFキャッシュ・open待ち・render待ち処理を共通化した。利用中のdocumentを閉じないことと、同一documentの描画を直列化することを同じ場所で保証する。
- 通常の保持上限6documentは維持。すべて使用中なら一時的に上限を超え、アイドル化後に削減する。処理中のdocumentを上限維持のために強制closeしない。
- 未使用の `_resolveIdentities`, `_categoryLabel`, `_filteredAssignedTags`, `_loadReaderBytes`, `_canUseInitialPreload` を削除した。呼び出されているcontroller本体は維持。
- 未使用の `printing` を削除し、推移依存 `pdf_widget_wrapper` もlockから除かれた。実行時に必要な `photo_view`（pdfx経由）や `sqlite3_flutter_libs` は残した。
- `path_provider_platform_interface` は既存の推移依存をテスト用の直接依存として明示したもので、新しい実行時ライブラリーの導入ではない。
- ネットワークからディスクへの書き込みは受信速度だけで積み上げず、書き込み側に合わせて流す。nullプレビューも保持し、無駄な再探索を抑える。
- フレームレート・実PDFのRSS・読み込み秒数のベンチマークは未実施。改善倍率やメモリ削減量は未測定であり、数値的な高速化は主張しない。

## 実施した確認

Flutter 3.41.5 / Dart 3.11.3、Windowsで実行。各コマンド前に作業ディレクトリと `pubspec.yaml` の存在を確認した。

| 確認 | 結果 |
| --- | --- |
| `flutter pub get --offline` | 成功。不要依存だけを整理し、一括アップグレードなし |
| `flutter test --no-pub --reporter expanded` | **81件中80成功、1失敗**。失敗は既存の削除エラー文言不一致。ブラウザー限定3件はこの実行の対象外 |
| `flutter test --no-pub test/repository/pdf_resource_lifecycle_test.dart --reporter expanded` | **8/8成功**。Windows／Android／リモートの解放・競合・失敗後再試行 |
| 共通PDFキャッシュ／先読み／PDF出力／OAuth／HTTPの追加テスト | 全件成功（上の全件テストに含む）。native PDFはfakeを用いた順序検証であり、ネイティブエンジン実機検証の代替ではない |
| `python -m unittest discover -s server/tests` | **115件中112成功、1 assertion failure、2 errors**。残る3件は既存の文字化けしたテストデータ／期待値 |
| `python -m compileall -q server` | 成功 |
| `python -m pip check` | 成功（依存要求の矛盾なし。脆弱性の網羅的検査を意味しない） |
| `flutter analyze --no-pub` | **error 0、warning 19、info 91**。開始時124件→110件。既存警告があるため終了コードは非ゼロ |
| 最後に追加したリモート回帰テスト・JS検証ツールの対象限定解析 | 成功、指摘0件 |
| `dart compile js tool/pdfjs_safety_smoke.dart -o build/pdfjs_safety_smoke.js` → Node実行 | 成功。eval無効化、他のoptions／exports／戻り値の維持、二重適用の安全性を確認 |
| `flutter test --platform chrome test/web/pdfjs_safety_test.dart` | 実行不能。下記Windowsテストランナー問題により開始後停止し、中断。成功扱いにしていない |
| `flutter build windows --release` | **成功**。`build/windows/x64/runner/Release/pdf_viewer.exe` のProductVersion **1.0.206+216**、更新日時2026-10-09 23:51:49を確認 |
| `flutter build web --release --no-pub --no-web-resources-cdn --pwa-strategy=none` | **成功**。`build/web/version.json` でversion **1.0.206** / build_number **216**を確認 |
| `git diff --check` | 成功 |
| 変更ファイル46件の厳密UTF-8デコード | 成功。既存の文字化け内容を復元したという意味ではない |

ログ: `audit_flutter_final.log`, `audit_server_final.log`, `audit_pdf_tests.log`, `audit_analyze_final.log`, `audit_windows_build.log`, `audit_web_build.log`（作業用・Git管理対象外）。

## 未修正・未検証と理由

1. **既存の日本語期待値／文字化け**
   - `test/repository/remote_media_repository_test.dart:223`: 期待する「削除結果を確認できませんでした」と、既存実装の「削除確認に失敗しました: old.jpg」が不一致。削除失敗を例外にする挙動は維持。日本語文字列を無断変更しない指示に従い保留。
   - `server/tests/test_routes_actions.py:440`付近のrescanエラー期待値が文字化け。実際の `Rescan failed: db locked` と不一致。
   - 同ファイルの `:732`, `:760`付近のUnicodeアップロードテストデータに、異常に長い文字化けしたファイル名がある。Windowsで一時／出力ファイルを作成できず2件エラー。正しい元の日本語が分からないため、自動復元や別の短い文字列への置換はしていない。
   - コメントにも既存の文字化けがある: `lib/scene/detailImage.dart:67`, `:77`, `:80`, `:317`, `:426`、`lib/scene/gallery_thumbnail_cache.dart:194`。UTF-8として読めるが内容が既に崩れている。一括再エンコードはしていない。
2. **Webブラウザーテストの環境問題**
   - Windows上のFlutterテストサーバーでCanvasKit URLがパス区切りの判定に失敗して404になることを確認。ブラウザー側でWebAssembly取得失敗。またネストしたテストファイル名の区切りも失われる。
   - SDKは変更せず、テストを中断。ReleaseのJSビルドと、純粋なJS interopのNodeスモークテストで補完したが、Web API失敗時のブラウザー回帰2件は未実行のまま。
3. **解析警告・旧UIの残骸**
   - `gallery_home_view.dart` の旧ホーム実装、`web_remote_viewer_page.dart` の旧widget、protected `setState`利用、`dart:html`／`dart:js`・Flutter APIの非推奨などが残る。
   - 大きな旧UIブロックの削除や拡張メソッドの再配置は画面全体の確認を伴うため保留。今回の修正を隠すlint無効化は行っていない。
4. **依存・ビルド環境**
   - PDF.jsは公式回避策を適用したが旧版のまま。pdfxとの互換性、worker／cMapを含む更新検証が必要。他の既知脆弱性が存在しないことを保証する監査ではない。
   - Pythonは範囲指定requirementsで完全固定lockがなく、同じ環境の再現性に課題。インストール済み主要版はFastAPI 0.135.2、Starlette 1.0.0、Pillow 11.3.0、pypdfium2 4.30.0、python-multipart 0.0.22。無検証の一括更新はしていない。
   - Windowsビルドに外部プラグイン由来のCMake警告、WebビルドにWasm dry-run失敗・CupertinoIcons不足・PWA引数非推奨の警告が残る。Windows／JS Webの生成は成功したが、Wasm対応や全画面アイコンの正常表示を確認したものではない。
5. **引き続き統合検証が必要な設計課題**
   - PDFの利用／破棄は保護したが、rename/deleteとファイル操作全体を一つのトランザクションにしていない。外部編集の検知、ファイル変更直後のキャッシュ失効、操作中の再オープン防止は別途必要。
   - リポジトリ終了時のPDF利用は待機する一方、ネットワーク転送・サムネイル生成全体に共通するキャンセル契約はない。
   - サーバーの起動初期化がyield前に失敗する経路は、正常終了時とは別にリソース解放の検証が必要。
   - 一覧／詳細／Web画面に大きなStateと旧新の責務が混在。表示仕様を固定する画面テストを追加した上で段階的に分割するのが適切。
   - サーバー認証・HTTP/LAN公開方針は現在の設定仕様を維持。公開環境のアクセス制御・TLS・URL取り込みの脅威モデルについては別途運用条件に沿った検証が必要。

## 推奨する次の順序

1. 文字化けしたテストデータの正本と、日本語エラー文言の期待仕様を確定して、全件テストをグリーンにする。
2. 実機で大容量PDF、素早いファイル切り替え、描画中の削除／rename、破損PDF、Android SAF、ページ編集、履歴復元、ズーム／スクロールを確認する。
3. Webテストを実行できる環境を整え、PDF.js更新と互換性テストを独立した変更として行う。
4. 旧UIの未使用部分、State分割、キャッシュ無効化／キャンセル契約、起動失敗時のサーバー解放を小さな単位で整理する。
