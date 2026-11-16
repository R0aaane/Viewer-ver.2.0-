# このPCのComfyUIで生成し、画像をホストへ送る

状態: 実装・実GPU検証済み（2026-11-17）。根拠: `LocalGenerationService`、ホームの `_openLocalGeneration`、`local_generation_live_test.dart`。

## 操作

1. Windows版のホームで「AI画像を生成」→「画像生成を開く」。必要ならComfyUIとローカル生成サービスが起動する。
2. 生成画像画面の「画像を生成」から、プリセット・描きたい内容・サイズ等を指定し、画面下部の「生成する」を押す。
3. 生成履歴で完了を確認する。完成画像の履歴をタップするとギャラリーへ戻る。
4. 画像のチェックを選び「ホストへ送る」。現在のクライアント接続先の生成画像専用ギャラリーへ画像をアップロードする。通常のPDFライブラリとは分離される。

転送は選択時に行う。失敗してもローカルの原本を保持し、再試行できる。既存の重複スキップ付きアップロードを利用する。生成処理を実行するPCとホスト接続設定は分離している。

## この環境

- ComfyUI: `E:\Program\AI\ComfyUI_windows_portable`。既存のembedded Pythonと`extra_model_paths.yaml`を使用。
- GPU: NVIDIA GeForce RTX 5060 Ti、VRAM約16GB。
- 初期プリセット: `waiIllustriousSDXL_v160.safetensors`、1024×1024、20 steps、CFG 5、1枚。v150も選択可能。
- 原本出力: ComfyUIの `output/PDFViewer`。この専用サブフォルダのみ取り込む。
- 接続・プリセット: workspaceの `data/local_generation/connection.json` と `presets.json`。生成原本・SQLiteも同ディレクトリ配下。これらはマシン固有のためGit対象外。

ComfyUIのlocalhost:8188と、既存FastAPIを別の保存先で起動するlocalhost:18890を使用する。後者は専用の認証トークンをWindowsのsecure storageに保持し、ホストの認証トークンを共有しない。アプリを閉じても起動済みのComfyUI・生成ワーカーは継続する。

現状はWindowsと既存workspace内のRelease配置に対応する。workspaceと`.venv`が必要。別PCへ移す際は接続設定の絶対パスとモデル名を実環境に合わせる。Webからこのローカル実行機能は起動しない。

## 確認結果

Windows profileアプリの生成ボタンから実GPUでPNGを1枚生成。既存クライアント設定のホストへ同じ画像を送信し、HTTP 200・importedCount=1を確認。ComfyUIの処理ログは初回モデルロード込み74.49秒。画像は1024×1024、約2.05MiB。原本の埋め込み生成情報を保持して転送する。

関連UI・Repositoryテスト22件成功。実画像を生成・転送するテストは `LIVE_COMFY_TEST=true` を明示した場合だけ動く。通常のテスト実行でホストへアップロードしない。

ComfyUIの追加ノードには既存のGroundingDINO・Triton不足やManagerのチャネル警告がある。今回使用する標準のCheckpointLoaderSimple・KSampler・VAEDecode・SaveImageでの生成は成功した。追加ノード全般の動作は未確認。

## 2026-11-17 更新

生成画像のホスト送信は `/generated/upload` を使い、通常のPDFライブラリ取り込み・整理処理から分離した。ホスト側もこのAPIを含む新版の起動が必要。未更新のホストへの送信は失敗し、ローカル画像は保持される。一覧の選択後に「削除」で削除済みへ移動し、削除済み表示から復元できる。物理ファイルの完全消去は行わない。従来の試験で通常ライブラリへ送った画像の移動・削除は自動実行しない。
