# 30,000枚の品質・性能確認（2026-11-11〜12）

## 測定環境・範囲

- Windows build 26200、AMD Ryzen 9 PRO 8945HS、16論理CPU、使用可能な物理RAM 29.78GiB。
- Flutter 3.41.5、Python 3.10.6、SQLite 3.37.2、Pillow 11.3.0。
- 実ファイル30,000枚、100フォルダ、合計8.289GiB。512×768、768×512、768×1024、1024×768のPNGを各25%。
- 4種類の決定的なパレット画像を再利用し、個別のprompt・seed・workflowを埋め込んだ合成データ。ファイル内容のSHA-256は全件異なる。実写画像・大きなRGBA画像・動画の負荷分布は再現していない。
- 本番DB・原本とは分離した `.dart_tool/performance30k` の専用ライブラリを使用。手動タグ2件/画像、お気に入り約10%、100枚追加の差分も用意。
- HTTPは認証付きの実際のFastAPIとRepositoryを127.0.0.1で実行。OSのファイルキャッシュはフラッシュしていない。HTTP検索は各条件5回のウォームアップ後30回、サムネイルは48要求、同時アクセスは16クライアント・160要求。
- 生成キューは実際のジョブサービスと0.2秒の模擬ComfyUIを使用。GPU生成時間・Tailscale/WAN・Android実機の性能は未測定。
- WebはReleaseビルドを確認した。ブラウザでの30,000枚性能は未測定。

## 最終コードの取り込み実測

検索用の追加索引も含む最終コードで、空の専用ライブラリに30,000枚すべてを取り込んだ。旧版は11日、最終版は12日に測定しており、OSキャッシュ状態は揃えていない。

| 項目 | 旧コード | 最終コード |
|---|---:|---:|
| 初回の30,000件観測 | 75.98秒 | 8.29秒 |
| 先頭2,000枚の取り込み | 136.76秒 | 62.88秒 |
| 30,000枚の取り込み本体 | 未完走 | 1,006.34秒 |
| 初回合計（観測＋2.1秒安定待ち＋取り込み） | 未完走 | 1,016.73秒（16分56.73秒） |
| 変更なしスキャン・3回中央値 | — | 1.98秒 |
| 100枚追加・2回スキャン＋2.1秒安定待ち | — | 9.01秒 |
| 取り込み中のOSピークRSS | — | 116.96MiB |

素材の作成、サービス初期化、測定用の手動タグ投入は初回合計に含めない。変更なしの実測3回は2.303 / 1.937 / 1.981秒。改善途中に同じ完成済みDBで新旧を各3回比較した中央値は、旧5.51秒→新1.81秒だった。

100枚追加後の30,100件では原本8.307GiB、サムネイル1.556GiB。初期の取り込み改善直後の測定と、追加索引を含むこの最終測定は区別し、最終コードのソースSHA-256も保存した。

## 検索・同時アクセスの実測

HTTP検索のp95（ms）。旧SQL測定は100枚追加後、新SQL測定は模擬ジョブ画像も追加したカタログで実施した。同じ完成済みカタログ上での新旧33条件の返却内容照合も別途実施している。

| 条件 | 旧SQL | 新SQL |
|---|---:|---:|
| 先頭ページ | 451.97 | 10.82 |
| offset 14,976 | 282.35 | 85.45 |
| offset 29,952 | 275.99 | 154.59 |
| 名前順 | 217.83 | 174.66 |
| 古い順 | 277.81 | 9.89 |
| 一般的なprompt | 66.84 | 6.84 |
| 希少なprompt | 76.92 | 7.69 |
| お気に入り | 238.56 | 11.72 |
| 手動タグAND | 286.49 | 49.91 |
| 手動タグNOT | 583.34 | 12.83 |
| 16同時・160検索 | 3,108.61 | 672.78 |

16同時・160検索の全体所要時間は16.45→2.13秒。最終HTTPサムネイル応答は中央値7.34ms、p95 8.56ms（48要求）。このHTTP負荷中の実PythonワーカーのOSピークRSSは118.78MiBだった。

生成キュー12ジョブの投入→開始待機は、旧処理の中央値15.29秒・p95 33.46秒に対し、新処理は中央値4.60秒・p95 6.16秒。模擬GPUを含む投入→完了のp95は33.77→6.54秒。SQLiteやスキャンとの競合も含む実測であり、実GPUの処理能力を表す値ではない。

## Windowsギャラリーの実測

既存の `GeneratedGalleryPage` と `GeneratedMediaRepository` を使い、MaterialAppのホームに配置した計測用profileアプリで実行。30,136件・全628ページを巡回し、各ページの上・中央・下の画像表示と、25ページごとのflingを実行した。viewportは1264×681、DPR 1、profileモード、バージョン1.0.240+250。

| 項目 | 実測 |
|---|---:|
| 初回画面の最初の画像（アプリ内キャッシュ空） | 216.59ms |
| 次ページの最初の画像・中央値 / p95 | 215.65 / 282.94ms |
| ページ内3位置の表示完了・中央値 / p95 | 477.70 / 590.00ms |
| 628ページ巡回の所要時間 | 326.18秒 |
| 初回差分履歴の追いつき | 10.57秒 |
| buildフレーム・p95 / 最大 | 11.52 / 22.61ms |
| rasterフレーム・p95 / 最大 | 3.93 / 13.80ms |
| Flutter RSS・開始前 / 終了時 / OSピーク | 115.87 / 263.32 / 283.62MiB |
| 圧縮画像キャッシュ最大 / 上限 | 31.999 / 32MiB |
| デコード画像キャッシュ最大 / 上限 | 99.984 / 100MiB |

フレームはページ遷移・画像構築・スクロールを含む計15,506フレーム。buildの最大値は16.7msを超えており、全フレームが60fps相当の予算内に収まったという結果ではない。各ページで両キャッシュの上限と画像取得エラーがないことを検証した。50〜600ページのRSSチェックポイントは約237〜266MiBで推移し、全件数に比例する画像の常駐は発生しなかった。

## 変更内容

- `generated_library.py`: 初回観測を500件ずつ記録し、未変更ファイルの不要な解決処理を省略。新規・変更ファイルのパス検査は継続する。
- 公開処理では不要な中間コミットを省き、生成情報・ready状態・イベントを一括確定する。stagedジャーナルと原本のatomic renameによる復旧を維持する。
- PNGサムネイルは対応する画像モードを保持し、圧縮レベル1を使用。リサイズ・EXIF補正の順序を維持し、原本を変更しない。圧縮率を下げるため、素材によってサムネイルのディスク使用量が増える可能性がある。
- `generated_catalog.py`: 既存DBに日付降順・名前の索引を追加。索引からページを選んだ後に詳細・編集バージョンを取得する。改名・削除・タグ・お気に入り・同時刻の順序を維持する。
- `generation_jobs.py`: ジョブの終了状態をコミットした後に待機中のキューワーカーを起こす。
- 計測用APIはベンチマーク専用factoryだけに追加し、通常のサーバー起動には追加しない。

## 検証方法と注意点

- 新旧SQLを同じ完成済みカタログで33条件比較し、返却内容・順序・バージョンが一致した。時間は単発比較として別途保存し、HTTPのp95とは区別する。
- 旧取り込みコードはハッシュを照合したスナップショットを使用。旧コードの30,000枚初回取り込みは完走しておらず、最初の2,000枚までの比較値から全件時間を推計しない。
- 変更なしスキャンは同じ完成済みカタログで新旧を各3回測定し、ワーカーロックを取得できなかった実行を除外した。
- 生成待機時間は同じサーバーで旧・新のキュー更新処理を切り替え、各12ジョブを投入した。キュー待機とGPU処理時間を区別する。
- Windows venvのランチャーPIDは実際のPythonワーカーと異なる。最終HTTP計測ではワーカー自身からPIDを取得してRAMを測定した。初回比較データのランチャーRAM値は無効として扱う。
- Flutterは既存のWindows integration_testドライバーを使うprofileモードで測定。起動直後のアプリ内画像キャッシュは空だが、OS・サーバー側は温キャッシュである。

## 回帰確認・成果物

- 関連Pythonテスト42件が成功。検索の改名・削除・同時刻ページ境界・編集バージョン、透過パレット、公開途中のロールバックと再実行を確認した。
- 既存host DBを読み取り専用でコピーし、コピー上の移行で記録・タグ・お気に入りの件数保持とSQLite整合性を確認した。通常実行でskipされたこの1件は、対象DBを指定して別途成功を確認した。
- FlutterのRepository・差分同期・ジョブ画面テスト4件、Windows全628ページのprofileテストが成功。計測コードの限定的な静的解析も指摘なし。
- ギャラリー計測に使った30,136件は、原本の全SHA-256と画像検査、全サムネイルの存在、61件のサムネイルデコード、SQLite整合性を確認した。手動タグ60,200件・お気に入り3,010件を保持。
- Windows / Web Releaseを1.0.240+250で更新。WebビルドではWasm dry runとCupertinoフォントの警告が出ており、Wasm実行は検証していない。

生データは [results](results/) に保存した。主なファイルは [最終取り込み](results/ingestion-final.json)、[旧版部分測定](results/ingestion-baseline-partial.json)、[HTTP旧](results/http-before.json)、[HTTP新](results/http-after.json)、[Windows profile](results/windows-profile.json)、[キュー比較](results/job-comparison.json)、[検索一致照合](results/query-equivalence.json)、[ギャラリー整合性](results/gallery-verification.json)。一時認証トークンは含めない。

最終コードの30,100件でも全原本SHA-256・画像・全サムネイル存在・61件のサムネイルデコード・SQLite整合性と、手動タグ60,200件・お気に入り3,010件の保持を確認した。詳細は [最終取り込み整合性](results/ingestion-verification.json) を参照。

所有マーカーと解決済みパスを確認して計測用の大容量データを削除し、一時認証ファイルも削除した。Eドライブの空き容量は 58.229GiBまで回復。結果JSONと小さな比較用スナップショットは保持した。[Release成果物・確認記録](results/validation.json) に版・ハッシュ・検証件数と後片付けの確認を記録した。

## 再測定

すべてプロジェクトルートで実行する。既存の計測用ディレクトリを再利用せず、空いている専用ルートを指定する。約30GiBの空き容量を確保する。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'project root required' }
.venv\Scripts\python.exe -m tool.benchmark_generated_library prepare --root .dart_tool/performance30k-rerun --count 30000
.venv\Scripts\python.exe -m tool.benchmark_generated_library measure --root .dart_tool/performance30k-rerun --label rerun --port 18880
```

`ready_for_flutter` の表示後、別のプロジェクトルートのターミナルで実行する。認証トークンは一時controlファイルから読み込み、コマンドや報告書へ転記しない。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'project root required' }
flutter drive --profile --no-pub --driver=test_driver/integration_test.dart --target=integration_test/generated_gallery_performance_test.dart -d windows --dart-define=BENCH_CONTROL_PATH=E:\_workspace\Flutter\pdf_viewer\.dart_tool\performance30k-rerun\control.json
.venv\Scripts\python.exe -m tool.benchmark_generated_library verify --root .dart_tool/performance30k-rerun --label rerun
```

成功すると専用サーバーが終了する。小さな結果JSONを保存してから、次で専用データだけを削除できる。削除処理は所有マーカーとworkspace内の解決済みパスを検証する。取り込みのみ再計測する場合は `measure` に `--no-serve` を追加する。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'project root required' }
.venv\Scripts\python.exe -m tool.benchmark_generated_library clean --root .dart_tool/performance30k-rerun
```
