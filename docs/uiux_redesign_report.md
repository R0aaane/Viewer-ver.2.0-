# UI/UX改善 実装報告

## 追加実装（2026-11-18、1.0.253+263）

### 変更

- ライブラリのアイテムメニューに「詳細を見る」を追加。1180px以上では右側の詳細パネル、狭い画面とホームからはボトムシートを使う。表紙・ファイル情報・カテゴリ別タグを表示し、既存のタグ追加画面と閲覧画面へ接続する。
- 詳細パネルは対象アイテムのタグだけを取得。読み込み失敗とタグなしを区別し、再試行、編集・閲覧から戻った後の再取得に対応。対象を切り替えたときに古い非同期結果を表示しない。
- ビューアは閲覧を維持しながら右側で既存のタグ編集・評価・関連作品・PDFページ一覧を操作できる。狭い画面では従来の詳細タブを使う。
- 閲覧設定・フォルダ切替は全画面幅で設定ドロワーへ集約。画像解析・お気に入り・しおり・削除は既存コールバックを維持し、小画面では操作メニューへ整理。
- デスクトップの閲覧ツールバーを1段に集約。フルスクリーンではヘッダーを隠してコンテンツを広く表示し、解除ボタン・Escape・戻る操作を維持する。詳細タブからフルスクリーンへ入ると閲覧タブへ切り替える。
- ホームは検索・読書再開・最近閲覧・最近追加・お気に入りを中心に構成。空の棚は省き、登録フォルダなしのときは初期導線を表示。画像生成機能はホーム下部の折りたたみ領域に残す。
- ホームの作品カードも共通化。再開カードには進捗を表示し、記録済みのページ番号を既存の閲覧処理へ渡す。ホーム検索エラーも画面に表示する。
- 色・角丸・余白を前段階と統一し、文字拡大時は詳細見出しや評価ボタンを折り返す。データ形式・検索のマッチ条件・ファイル操作・閲覧位置の保存処理は変更していない。

### 主な追加・変更ファイル

- `lib/scene/gallery_inspector.dart`、`widgets/library_inspector.dart`、`widgets/inspector_pane.dart`: 詳細パネルとボトムシート。
- `lib/scene/detailImage.dart`、`detail_widgets.dart`、`detail_tag_panel.dart`、`reader_view.dart`: 閲覧・詳細・設定・集中表示の配置。
- `lib/scene/gallery_home_view.dart`、`widgets/reading_resume_card.dart`: ホームと再開カード。
- `lib/scene/gallery_grid_view.dart`、`gridGallery.dart`、メニューenum、版番号3か所: 既存画面への接続と版更新。
- `test/inspector_resume_test.dart`、`test/scene/reader_layout_test.dart`、`test/support/ui_review_capture.dart`: 部品・画面統合テストと任意の画像保存。

### 確認結果

- 全体 `flutter test --no-pub --reporter expanded`: **169件成功、1件スキップ**。既存の明示指定が必要な計測テストがスキップ対象。
- 最終lint修正後の関連2ファイル: **14件成功**。詳細の再取得、エラーからの再試行、遅延結果の排除、再開ページの受け渡しを確認。
- 実際のホーム・ライブラリ・ビューアWidgetを模擬リポジトリで起動。360／1280pxで詳細導線、右パネル／シート、設定、フルスクリーンへの出入りを確認。ビューアは文字1／2倍、詳細部品は320／380px・文字2倍でも検証。
- 右パネル開閉でビューア画像の追加レンダリングが発生しないことを確認。全体の実測性能を保証するものではない。
- `flutter analyze --no-pub lib/scene lib/app lib/widgets`: **エラー0、警告10、info 26**。既存のprotected member参照と無効化されたコード等が残り、終了コード1。
- Windows Release: **1.0.253+263**。ビルド成功と、実行ファイルのFileVersion／ProductVersion・ビルド開始後の更新を確認。既存プラグインのCMake CMP0175警告は残る。
- 差分・UTF-8検査を実施。既存の文字化けコメントは推測で変換していない。

### 画像と未確認事項

`build/ui_review/home_360.png`、`home_1280.png`、`library_inspector_1280.png`、
`reader_1280_1x.png`、`reader_360_2x.png`等を生成して目視確認。
今回は実際の画面Widgetを使うが、素材・メタデータはテスト用。実アプリの本番ライブラリを操作した画像ではない。

Android実機のSAF・権限操作、実データでの一括操作、Windows実行ファイルの手操作、
大量データでのメモリ・フレーム時間測定は未確認。ライトテーマ切替と表示設定の永続化は追加していない。
ライブラリの簡易詳細はタグ追加まで対応し、削除を含む既存の詳細編集はビューアの詳細・タグ画面で行う。

---

## 前段階の記録（1.0.252+262）

確認日: 2026-11-17。対象版: 1.0.252+262。

## 調査と方針

指定の指示書はリポジトリ内にはなく、Downloadsの添付ファイルを参照した。
ホーム、ギャラリー、PDF一覧、外部検索の既存導線を維持する。
生成画像管理も実装済みのため、既存メニューから引き続き利用できる。

優先課題は、表紙とタイトル・操作の重なり、固定高さのライブラリヘッダー、
狭い画面での一括操作の過密、検索条件の見通し、共通テーマの一貫性。
サムネイルの同時処理制限・キャッシュ、PDF閲覧キャッシュは既存実装を維持した。
DBスキーマ、検索のマッチ条件、ファイル参照、取り込み・改名・削除の処理は変更していない。

## 実装

| ファイル | 変更 |
|---|---|
| `lib/app/app_theme.dart` | インディゴ基調、暗い中性色の面、文字色・境界線・選択色を統一。主要ボタンは48dpの最小寸法。下部ナビ・ドロワーのテーマを共通化 |
| `lib/scene/gridGallery.dart` | 小画面にホーム／ライブラリ／PDF一覧／外部検索の下部ナビを追加。ライブラリヘッダーを中央コンテンツに配置し、高さ不足時はヘッダーをスクロール可能にする |
| `lib/scene/gallery_grid_view.dart` | グリッド／遅延構築リスト、通常／大きな表紙、contain／cover、件数表示、検索0件からの全解除、Ctrl・Shift選択、小画面の選択操作メニュー |
| `lib/scene/widgets/library_media_card.dart` | 表紙とタイトル・補助情報・操作を分離。選択を枠・背景・チェックで表示。150msの状態遷移とOSの動きを減らす設定に対応 |
| `lib/scene/widgets/library_view_controls.dart` | 表示オプションと検索トークンの個別解除。既存の空白区切り検索構文に合わせてトークンを扱う |
| `lib/scene/gallery_search.dart` | タグ条件だけがある場合にも全解除を提供 |
| `lib/widgets/controller_focusable.dart` | フォーカス表示と自動スクロールで動きを減らす設定を尊重 |
| `pubspec.yaml`・アプリ／Webの版番号既定値 | 1.0.252+262に統一 |

表示切替では検索条件・並び順・選択状態を変更せず、同じスクロールビューを使う。
表示設定は画面State内で保持し、アプリ再起動後の永続化は追加していない。
表紙の暗色フィルターを除去して本来の色を表示し、不要な色フィルター描画を減らした。
実測の速度改善率は未計測。

## 検証

- `flutter test --no-pub --reporter expanded`: **155件成功、1件スキップ**。
  スキップは既存の `MEASURE_FOLDER_PAGE` 指定が必要な計測テスト。
- `test/library_presentation_test.dart`: 検索トークンの個別解除・全解除、
  お気に入り、表示切替、表示オプション、動きを減らす設定、
  320／600／1280pxと文字倍率1／2倍のカード・操作部品を確認。
- `flutter test --no-pub --dart-define=UI_CAPTURE=true test/library_presentation_test.dart --reporter expanded`:
  **9件成功**。上記7件に390／1280pxの画像生成確認2件を追加。
  画像生成オプションのみWindowsのMeiryoを使用する。
- `flutter analyze --no-pub lib/scene lib/app lib/widgets`:
  **エラー0、警告10、info 26**。終了コード1なので解析全体の合格とは扱わない。
  警告は既存の `gallery_hitomi_search.dart` のprotected member参照と
  `gridGallery.dart` の無効化されたタグセクション。
- Windowsではファイル名の大小文字を含む単一ファイル指定でpart解決エラーが出たため、
  関連ディレクトリ指定で再解析した。
- `flutter build windows --release`: **成功**。
  `build/windows/x64/runner/Release/pdf_viewer.exe` の更新時刻がビルド開始後であること、
  FileVersion／ProductVersionが **1.0.252+262** であることを確認。
  `webview_windows`由来のCMake CMP0175警告は残る。
- `git diff --check`: 成功。

## 視覚確認

`build/ui_review/library_components_390.png` と
`build/ui_review/library_components_1280.png` を保存して目視確認した。
実装済み共通部品を使ったテスト用画面であり、本番ライブラリのスクリーンショットではない。
表紙もテスト用の色面・アイコン。変更前の実画面キャプチャは取得していない。

## 未確認・残課題

- Windows実アプリの全画面遷移・右クリック・実データの一括操作、Android実機のSAF・権限・戻る操作。
- ライブラリ全体のウィジェット統合テスト、表示切替時の同一アイテム位置への厳密な追従。
- 大量素材のスクロール時間・メモリ実測。全件フル解像度デコードを追加してはいない。
- 右側インスペクター、ライトテーマ切替、ビューア・ホーム・コレクション固有の全面的な再設計。
  今回は共通テーマの適用とライブラリ中心の段階実装。
- 既存コメント `gridGallery.dart` の `Tags (SharedPreferences…` に文字化けがある。
  元の文言を推測せず、そのコメントは変更していない。変更した日本語に文字化けはない。

## 設計参考

- [Adobe Acrobatの再設計](https://adobe.design/ideas/megaverbs-and-the-making-of-a-modern-adobe-acrobat): 操作目的とプラットフォーム間の一貫性。
- [Fluent 2 Motion](https://fluent2.microsoft.design/motion): 状態を理解するための短く控えめな動き。
- [Flutter Adaptive & Responsive](https://docs.flutter.dev/ui/adaptive-responsive): 画面幅と入力方法への適応。
