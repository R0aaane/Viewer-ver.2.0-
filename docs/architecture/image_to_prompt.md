# Image to Prompt（このPCを解析ホストとして利用）

状態: 実装、2026-11-17。既存PDF・画像Repositoryのページ描画、FastAPIの認証、Pillow、SQLiteを再利用する。既存PDFタグDB・生成画像DBは変更しない。

## 使い方

PDFを開き、解析したいページを表示して上部の画像検索アイコン「Image to Prompt」を押す。通常画像・生成画像の詳細からも利用できる。「この画像を解析」で手動実行し、容姿・服装・表情・ポーズ・構図・背景などのカテゴリを確認する。

カテゴリのスイッチで一括有効／無効、タグのチェックで個別選択、タグのクリックで文字列・カテゴリ編集、×で削除、「タグを追加」で追加する。選択内容から英語プロンプトが更新され、「プロンプトをコピー」でコピーできる。「結果を保存」で画像・PDFページに紐づけて保存し、同じ入口から再編集する。

再解析は新しい候補を作り、保存済み編集を自動上書きしない。保存時に版番号を照合して競合は409とする。WD14の数値は分類スコアであり正解確率ではない。Qwenには数値を捏造しない。同一の空白／underscore表現を統合して両方の出典を保持し、髪・目の色の競合は確認事項として残す。複数人物の属性を一意には断定しない。レーティングは既定でプロンプトから除外する。

## 構成・資源

- Windowsアプリが独立したFastAPI解析ホストを127.0.0.1:18891で起動する。既存のリモートライブラリ接続先を変更しない。専用トークンをWindowsのSecureStorageに保存し、既存ライブラリのトークンを流用しない。LANへ新しいポートを公開しない。
- PDFページは既存Repositoryで描画し、対象画像だけをAPIへ送る。PDF全体を解析サーバーにコピーしない。自動解析はしない。
- 設定: `data/local_analysis/config.json`。`ollamaUrl`（localhost限定）、`wd14Directory`（model.onnxとselected_tags.csvのディレクトリ）、`numGpu`（既定-1、GPUを利用。0でCPUへ変更）を指定する。変更は解析ワーカーの再起動後に反映する。
- 指定モデル: Ollama `qwen3-vl:8b-instruct`（Qwen3-VL 8Bの公式Instruct版）。既存の `qwen3:8b` は画像対応モデルではないため代用しない。`ollama pull qwen3-vl:8b-instruct` で導入する。Ollamaが停止中ならホスト上で起動する。
- WD14: 既存 `SmilingWolf_wd-v1-4-convnextv2-tagger-v2` のONNXとCSVを利用。`requirements.txt`に加えて `requirements-image-prompt.txt` を仮想環境へ導入する。通常サーバーは追加ライブラリがなくても起動可能。
- 同時解析は1件。Qwenのコンテキスト4096、画像1280px以内、応答1400トークン以内、解析の読取タイムアウト300秒・ストリーム全体600秒を上限とする。初回ロード・CPU解析には時間がかかる。WD14はCPUで逐次実行し、Qwenはkeep_alive=0で解析後アンロードする。
- このPCの既定はQwenをGPUで実行し、WD14はCPU。GPU共通ロックとComfyUIの追加ガードで生成と解析を順番に実行する。待機・モデル解放・解析時間を画面に表示する。
- モデル読込・Qwen解析・WD14読込・WD14解析・統合の段階をAPIでポーリング。推論にない進捗率は作らない。画面を閉じてもホストで継続し、再度開いてジョブに接続可能。ホストの再起動で中断されたジョブは失敗として明示し、無断再実行しない。

## 保存とAPI

解析専用 `data/local_analysis/image_prompt/image_prompt.sqlite` にジョブと編集結果を保存する。画像自体はDBへ保存せず解析の間だけメモリに保持する。出典はライブラリ接続先・メディアID・ページ番号で識別し、解析した画素画像のSHA256も保持する。PDFページの並べ替え・画像差し替え後は再解析して保存し直す。解析結果は既存PDFタグへ自動付与しない。

APIは `/image-prompt/configuration`、`POST /image-prompt/jobs`、`GET /image-prompt/jobs/{id}`、`GET/PUT /image-prompt/document`。既存FastAPIにも同じrouterを登録してあり、一般ホスト構成では `MEDIA_SERVER_WD14_DIR`、`MEDIA_SERVER_OLLAMA_URL`、`MEDIA_SERVER_IMAGE_PROMPT_NUM_GPU` で設定可能。

バックアップにはこの解析DBも含める。既存の本体DB専用バックアップに自動追加する変更はしていない。実行中のコピーはSQLiteのbackup APIを利用するか解析ホスト停止後に行う。

## 参照仕様

Ollama chat API: https://docs.ollama.com/api/chat
Qwen3-VL: https://ollama.com/library/qwen3-vl
WD14の公式前処理（白背景・正方形パディング・RGB→BGR・float32）: https://huggingface.co/spaces/SmilingWolf/wd-tagger/blob/main/app.py

実装とテストの根拠: `server/services/image_prompt_service.py`、`server/tests/test_image_prompt.py`、`test/scene/image_prompt_page_test.dart`。実機テストは `LIVE_IMAGE_PROMPT_TEST=true` を明示した場合のみモデルを実行する。

## CPU初期実装時の検証結果（2026-11-17）

- サーバー: 解析API・保存競合・再解析時の編集保持・接続エラーを含む新規4件、既存生成・PDF APIを含む合計20件成功。
- Flutter: 選択プロンプトの重複排除・カテゴリ無効化・版番号付き保存と既存生成画面など合計6件成功。静的解析エラー0（既存の警告・infoあり）。
- Windows profile実機テスト: 既存WindowsFolderRepositoryでテスト用PDFの1ページを画像化し、このPCのFastAPIを経由して両モデルを実行。WD14候補15件、統合後28候補。画面から保存し版番号1・英語プロンプト保存を確認。CPU実行のテスト全体は約3分20秒。実画像での認識精度を保証するベンチマークではない。
- Qwen3-VL:8bはこのPCの既存Ollamaへ追加導入。既存WD14モデルをそのまま使用し、既存モデル・ComfyUI設定は変更しない。CPU実行時のOllama使用VRAM0を確認。

## GPU排他制御（2026-11-17 更新）

- 共通ロックは `data/gpu_coordination.sqlite`。両Windowsワーカーが同じ `MEDIA_SERVER_GPU_LOCK_PATH` を設定する。モデル状態を確認できない場合は新規GPU処理を保留する。
- アプリの生成ワーカーはQwenのアンロードを `/api/ps` で確認してからComfyUIへ送信する。生成ジョブが終わるまでGPUロックを保持する。
- 解析ワーカーは生成完了を待ち、ComfyUIの `/free` にモデル・キャッシュ解放を要求。追加ガードのロード済みモデル数0とPyTorch予約量を確認してからQwenをロードする。このComfyUIは動的VRAM管理のためPyTorch値だけでは判定しない。
- 解析後はQwenのアンロードを確認してからロックを解放する。確認できなかった場合はガードを残し、アプリから次に再試行する際にもアンロード確認を行う。
- ブラウザーの通常生成も保護するため、既存ComfyUIへ `custom_nodes/pdf_viewer_gpu_guard` を追加した。元ソースは `tool/comfyui_gpu_guard/__init__.py`。同フォルダの `config.json` に `lockPath` として共通ロックの絶対パスを指定する。追加・変更時は生成待機列が空の状態でComfyUIを再起動する。
- ガードは `/prompt` と `/api/prompt` の新規送信を解析中HTTP 503で拒否し、実行中の生成は中断しない。状態確認は `/pdf-viewer/gpu-guard`（protocol 2）。独自プラグインが通常の送信経路を通らずGPUを直接使う場合は、このガードの対象外。
- 元のThinking版は結果ではなく思考出力で上限に達するケースを実機確認したため、同じ8BのInstruct版を採用。旧モデルを削除せず、保存済み結果はそのまま保持する。CPU/GPU比較はInstruct版・同じPDF画像・同じ推論設定で行う。
- 再測定: `python tool/benchmark_image_prompt_gpu.py --pdf <test.pdf> --wd <WD14-directory>`。ComfyUIが起動・アイドル状態で、protocol 2のガードが必要。生成テスト画像はComfyUIの `output/PDFViewer_Benchmark` へ出し、通常の生成画像監視ディレクトリに混ぜない。

GPU実測結果と検証根拠: [GPU性能・VRAM排他確認](../performance/image_to_prompt_gpu.md)。CPU 55.844秒、GPU 19.828秒（同じInstruct版・同じPDF画像、各1回）。

GPU化の最終検証: GPU排他・既存PDF/生成APIを含むPythonテスト29件、Flutterテスト6件が成功。Windows profile実機テストで画面からGPU解析・保存まで成功（その実行の解析本体15.641秒）。Windows Release 1.0.249+259のビルド・版番号を確認。

## PDF解析プロンプトの生成画面への引き継ぎ（2026-11-17）

1. PDFビューアで対象ページを表示し「PDFを画像解析」を押す。狭い画面では画像検索アイコンのまま表示する。
2. 「この画像を解析」でプロンプト候補を生成し、必要なカテゴリ・タグを選択する。
3. 「このプロンプトで画像生成」を押すと、このPCのComfyUI生成画面へ選択中の英語プロンプトを直接渡す。保存済みの結果からも利用でき、コピー・再解析・再保存は必須にしない。解析画面の未保存編集は保持する。
4. 生成画面でモデル・LoRA・枚数などを確認し「生成する」を押す。画面を開いただけでは生成しない。

通常のプリセットとLoRAプリセットを切り替えても、引き継いだプロンプトとその編集を保持する。送信結果が未確認のリクエストがある場合、その内容・キーは上書きしない。送信結果の確認または明示的なクリア後、「解析プロンプトを適用」で新しい入力へ切り替える。

生成履歴のサムネイル取得は履歴行の表示時まで遅延させる。削除済み画像は代替アイコンにし、画面外の履歴リクエストが未処理エラーを発生させないようにした。

引き継ぎの検証: Flutter関連10件と実機テストが成功。保存済みPDF解析の272文字をローカル生成フォームと照合し、一致・自動送信なしを確認。静的解析エラー0。Release 1.0.250+260。
