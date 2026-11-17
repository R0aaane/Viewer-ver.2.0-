# Image to Prompt GPU実測

2026-11-17確認。NVIDIA GeForce RTX 5060 Ti（16GB）、既存Ollama、Qwen3-VL 8B Instruct Q4_K_M、WD14 ConvNeXtV2 v2（CPU）を利用。

同じテスト用PDFの1ページを1280×960に描画し、同一画像SHA256・同一推論設定で各1回測定した。コンテキスト4096、temperature 0、出力上限1400トークン。GPU/CPU切替以外は同条件。結果はこの1ページの測定値であり、全画像への速度保証ではない。

| 処理 | CPU | GPU |
|---|---:|---:|
| Qwen読込・解析 | 53.781秒 | 16.578秒 |
| WD14読込・解析（CPU） | 1.625秒 | 2.062秒 |
| ComfyUI待機・モデル解放 | 0.000秒 | 1.063秒 |
| 解析全体（統合・Qwen解放含む） | 55.844秒 | 19.828秒 |

全体で2.82倍、約64.5%短縮。いずれも25候補を生成して正常完了した。モデルは毎回keep_alive=0で解放し、WD14セッションも解析ごとに作り直した。PDFの描画時間・通信・Flutter表示・保存時間は上表に含めない。

## VRAMと排他の実機確認

- 生成後のComfyUIモデル3個を `/free` で解放し、ロード済み0個になってからQwenを開始。
- GPU空き容量: 解放前8,875,514,618 bytes（約8.27GiB）→解放後15,823,011,840 bytes（約14.74GiB）。
- Qwenの最大GPU使用量: Ollama `/api/ps` のsize_vram報告値5,846,272,572 bytes（約5.45GiB）。プロセス全体のGPU使用量ではない。
- Qwen解析中、ComfyUIのロード済みモデル数は0を維持。PyTorchの予約領域64MiBは残るが生成モデルは保持しない。
- 解析中にComfyUIへ直接 `/prompt` を送るとHTTP 503で拒否。アプリ生成ジョブは待機状態を保持。
- Qwenのアンロードを確認後、待機していたアプリ生成が再開・正常完了。

再実行スクリプト: `tool/benchmark_image_prompt_gpu.py`。生の測定結果: [image_to_prompt_gpu.json](image_to_prompt_gpu.json)。テスト用の生成結果はComfyUIのPDFViewer_Benchmarkへ分離する。

以前のThinking版は思考出力だけでトークン上限に達するケースがあったため、同じ8Bの公式Instruct版へ変更。失敗した測定や、異なるThinking版の過去CPU時間は上の比較には使っていない。

最終確認: Python回帰29件・Flutter6件成功。別途、Flutter実機からGPU解析・保存するテストも成功（解析本体15.641秒）。後者はキャッシュ状態などが異なるため、上表のCPU/GPU倍率計算には用いない。Windows Release 1.0.249+259。
