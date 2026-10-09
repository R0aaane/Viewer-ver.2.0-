# 監査後の4工程

開始: 2026-10-10。前回修正の復元点: `9293d3f`。
ブランチ: `codex/pdfviewer-audit-followup`。既存UI・操作・保存形式を維持する。

## 完了条件と状態

| 順序 | 工程 | 完了条件 | 状態 |
| --- | --- | --- | --- |
| 1 | 既存テスト失敗と文字化け | Git履歴などの根拠から正しいデータ・仕様を特定し、無効化や根拠のない期待値変更なしでFlutter／Python全件成功 | 完了 |
| 2 | PDF統合検証 | 大容量、切替、描画とファイル操作の競合、破損、ページ編集、履歴、ズーム／スクロールを検証。端末／環境不足は未検証として記録し、完了に含めない | Windows自動実機検証6/6成功。Android SAFは端末不在で未検証 |
| 3 | Web・PDF.js更新 | ブラウザー回帰テストを実行し、更新したPDF.jsの描画・worker・cMap・破損ファイル処理を確認。更新は独立コミット | Chrome検証完了（8/8成功）。他ブラウザーは未検証 |
| 4 | 段階的な構造整理 | 使用されない旧UI、State責務、無効化／キャンセル、サーバー起動失敗時の解放を小単位で修正し、関連テストとビルドを確認。構造整理はPDF.js更新と別コミット | 第1段階の修正・回帰確認済み。全体の責務分割／全転送キャンセルは継続課題 |

仕様の根拠が不足する項目は保留して他項目を進める。未検証を完了扱いにしない。

## 作業記録

- 前回変更46ファイルをGitチェックポイントに保存。作業用ログはコミット対象外。
- 工程1の根拠: `8fab232` に元の `あいうえお_漢字混在.pdf`、`テスト画像.png`、`日本語フォルダ/テスト画像.png` を確認。4/1以降の複数回の誤変換で長い文字列になっていたため、その3行だけ復元。
- rescanの英語エラーは `327931b`（文字化けメッセージ正常化）で意図的に導入されていた。古いテスト期待値をその確定した契約へ整合。
- 削除確認エラーは `3599a95` で現行日本語へ変更され、テストだけが初版 `a6a2793` のままだった。現行全文を検証し、削除試行・確認が各1回、失敗時にID対応表を破棄しないことも追加検証。
- 対象確認: remote repository 17/17、server actions 23/23成功。製品側の文言・動作は変更していない。
- 全件確認: `flutter test --no-pub --reporter expanded` **81/81成功**、`python -m unittest discover -s server/tests` **115/115成功**。失敗テストの削除・skip・assertionの緩和なし。
- 工程1バージョン **1.0.207+217**。`flutter build windows --release` 成功。利用可能デバイスはWindows、Chrome、Edgeのみ（`build/audit_devices.json`）。

## 工程2: Windows実機

- `integration_test/pdf_windows_test.dart` を追加。Flutter SDK付属integration_testは開発依存のみ。ユーザーの設定・DB・PDFを使わず、一時生成PDF・一時ストレージ・メモリー上の設定・ループバックテストサーバーで検証する。
- 実際のpdfx Windowsプラグインで、1,000ページの先頭／中央／末尾、12ファイルを3巡する36描画、47,207,094バイトの画像PDFの先頭／末尾、ページ削除、rename、破損PDF後の正常描画を確認。
- 実際のImageDetailPageで、ページ移動、ピンチ拡大、パン、しおり、HTTP経由の読書進捗保存・再表示を確認。タグサービスだけはテスト用代替。
- 追加の実機回帰テストにより、rename後に旧パスを別PDFで再利用すると旧キャッシュの3ページが返る問題を再現（期待5ページ、実際3ページ）。`audit_native_rename_before.log` に失敗を保存。
- `PdfDocumentCache.mutateWhere` を追加。受理済みのPDF処理完了を待ち、該当ドキュメントを閉じ、ファイル変更完了まで新規PDF処理を待機させる。Windowsのrename／delete／ページ編集で使用。フォルダ配下の未オープンPDFにも対応するため、稀なファイル変更中はリポジトリ内のPDF処理を一時的に直列化する。
- バリア重複・変更失敗・終了との競合について単体テスト追加。共通キャッシュ／各リポジトリの対象テスト **15/15成功**、修正後のWindows実機テスト **6/6成功**。
- 修正後のFlutter全件 **84/84成功**。追加コード・テストの対象限定解析は指摘0件。既存Windowsリポジトリのinfo 3件はこの変更と無関係のため維持。
- 実行例: `flutter test --no-pub -d windows integration_test/pdf_windows_test.dart --reporter expanded`。Windowsネイティブアプリとして実行しており、PDFエンジンはfakeではない。
- 計測例（Debug・fixture生成も同じプロセス）: 36描画341ms、47MB PDFの2ページ描画252ms。生成後RSS 547MB→描画後626MB。fixture生成時のヒープを含むためアプリ実利用のピークや改善率を示すベンチマークではない。低メモリ実機・連続長時間測定は未検証。
- Android SAF実機は接続なし。Windowsでの自動操作をもってAndroid実機や人による操作感の確認済みとはしない。

## 工程3: Web回帰基盤と通信エラー

- Windows SDKの `flutter test --platform chrome` はCanvasKit配信パスの区切り文字処理で404となる。SDKは変更せず、公式integration_test／ChromeDriver経由へ移行。元のWebテスト3件は `integration_test/web_compatibility_test.dart` へ移動し、無効化していない。
- `tool/web_test_server.dart` はループバック専用の合成PDF／API。実ブラウザーで400応答後の再通信、memoized futureの失敗除去、不正JSON、401、PDF2ページの画素、破損後の正常描画を検証。
- 実行して、HTTPエラーが `HttpRequest.request` のProgressEventとして到着しステータスを失う不具合を確認。400を再試行し、401でもPDF本体へのフォールバックが起き得た。本文・バイナリ両経路で元のHTTPステータスとメッセージを保持する。非JSON応答もAPI例外へ統一。
- PDF生成ライブラリの赤／青定数はMaterial色だったため、テストfixtureを明示RGB原色へ訂正。画素の期待値は緩めていない。
- PDF.js更新前（3.11.174）のChrome実行 **6/6成功**。`audit_web_driver.log`。Chrome 154.0.8037.98／公式ChromeDriver 154.0.8037.92。
- 再実行: ルートで `dart run tool/web_test_server.dart`、ChromeDriverをポート4444で起動後、`flutter drive --driver=test_driver/integration_test.dart --target=integration_test/web_compatibility_test.dart -d web-server --web-hostname=127.0.0.1 --web-port=8765 --driver-port=4444 --headless --no-web-resources-cdn --no-pub`。
- 通信修正の復元点: `dcb9fb6`。PDF.js更新とは独立。

### PDF.js更新

- Mozilla公式 [v6.4.299](https://github.com/mozilla/pdf.js/releases/tag/v6.4.299) へ更新。本体・worker・cMaps・standard fonts・WasmのURLを同一版へ固定。モジュールscriptに対応し、eval無効化も維持。
- pdfx 2.9.2が呼ぶdocument.destroyはPDF.js 6でloadingTask.destroyへ移っていた。実ブラウザーで失敗を再現し、既存pdfxを変更せず互換関数を付与。開けなかったtaskも終了処理へ渡す。元のPromiseとJS例外を維持する（Dart Future往復による例外の変質を回避）。
- 外部cMapを必要とする非埋め込み日本語CIDフォントの合成PDFを追加。アプリのpdfx経由で描画し、別途「日本語」のテキスト復元を確認。PDFWorkerのportが実際のWorkerでありfake workerではないことも確認。
- 成功・失敗taskの終了回数、例外同一性、asset URL既定値と明示値の保持を追加検証。Chrome **8/8成功**（`audit_web_upgrade.log`）。追加interopコード・テストの限定解析0件、Nodeスモーク成功。
- **1.0.209+219**: Windows Release成功、exeのProductVersionと更新日時を確認。Web Release成功、version.jsonも一致。既存CMake／Wasm dry-run／CupertinoIcons／PWA引数の警告は残る。
- Chrome以外、オフラインCDN遮断時、全PDF機能／全フォントを網羅した互換性は未検証。既存のCDN依存は維持し、自己配信への変更は今回含めない。

## 工程4: 小単位の構造・終了処理整理

PDF.js更新の復元点は `9f9e5d2`。以下は別変更として実施。

### 問題・原因・変更ファイル

- `server/main.py`: 初期化がyieldの手前で失敗すると従来のfinallyに到達しなかった。ExitStackでDB生成直後からcloseを登録し、サムネイル→DBの依存順で解放する。`server/tests/test_lifespan.py` はschema、サムネイル生成、rescan、統計補完、alias補完の失敗、正常終了、close失敗を検証。修正前5失敗→修正後5テスト成功（subTestを含む）。
- `lib/models/reader_position.dart`（新規）、`lib/scene/reader_view.dart`、`detailImage.dart`、`detail_actions.dart`: ページ位置決定を純粋関数へ分離。PDFから解決済みのページ数を遅延履歴より優先し、ページ編集時にも更新。手動移動・明示初期ページ・読了時に先頭へ戻る既存契約は維持。
- `lib/scene/detail_reader_controller.dart`: endOfFrame待機中は、キュー上では開始済みでもPDFエンジンは未開始だった。この間の切替／disposeを世代番号で検知してキャンセルし、dispose後の新規描画要求も拒否する。エンジンで既に動いている描画は強制中断しない。
- `lib/scene/gallery_home_view.dart`、`gridGallery.dart`、`lib/web/web_remote_viewer_page.dart`: 静的解析で参照なしの旧ホーム、旧棚／マイリスト、旧ヘッダー／メタ情報widget、専用補助関数・未読フィールド、return後の到達不能Webカードを削除。旧UI関連は約1,000行減。現行表示で共有されるenum／項目選択関数は保持。現行UI文言・レイアウト・操作を意図的に変更していない。

### 確認結果

- `test/models/reader_position_test.dart` 5件、reader controller 4件、計 **9/9成功**。
- `integration_test/pdf_windows_test.dart` に、6ページPDFの読込後に「20/60」の古い履歴を遅延返却する実機回帰を追加。実表示が **6/6** に留まることを確認。Windows統合 **7/7成功**。
- Flutter全件 **91/91成功**（`audit_flutter_structure.log`）。Python全件 **120/120成功**（`audit_server_structure.log`）。
- 最終全体解析: **error 0 / warning 11 / info 90**。前回110件→101件。既存指摘が残るため解析の終了コードは1であり、警告ゼロとしては扱わない。
- **1.0.210+220**: `flutter build windows --release` 成功。exe更新日時2026-10-10 02:55:35／ProductVersion一致。Web Releaseも成功し、version.jsonのversion 1.0.210／build_number 220を確認。ビルド警告は工程3記載の既存項目と同じ。
- `git diff --check` と変更16ファイルの厳密UTF-8デコードに成功。
- 性能上の改善: 切替／終了後の未開始描画を省き、旧UI約1,000行を削除して保守対象を削減。エンジン自体の速度向上やメモリ削減率は測定していない。

## 未完了・未検証・残存リスク

- **Android SAF実機**: 接続端末がなく未検証。Windowsの実機結果で代用せず、工程2全体は完了扱いにしない。
- **Edge／Firefox／Safari、低メモリ／長時間連続利用、CDN遮断**: 今回未検証。Chrome 8件の成功は全ブラウザー／全PDFを保証しない。
- **構造整理の残り**: 巨大なGallery／Web State、Hitomi拡張のprotected setState警告9件、Galleryの非表示旧サイドバー、API内の不要cast、非推奨APIが残る。画面全体のテストが不足するため全面分割や一括非推奨置換は行わない。
- **無効化／キャンセルの残り**: 実行中のPDFエンジン・HTTP転送の統一キャンセル契約、外部編集のmtime監視、Android／Remoteのファイル変更とPDF利用の原子的連携は未完了。今回はWindows mutationバリアと詳細画面の未開始描画キャンセルまで。
- **保存の安全性**: PDFページ編集の電源断時の原子保存、ページ情報読込失敗時の履歴保存方針などは追加の仕様確認・失敗注入テストが必要。実ユーザーファイル／DB／設定の破壊的操作は実行していない。
- 元から存在する日本語コメントの文字化けは一括変換せず維持。復元の根拠が確認できたテストfixtureのみ工程1で修復した。

4工程すべての検証完了とはしていない。利用可能なWindows／Chrome環境で再現・確認できた修正を保存し、上記を継続課題として残す。
