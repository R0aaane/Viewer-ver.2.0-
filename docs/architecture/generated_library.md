# 生成画像の取り込み（Phase 2）

既存FastAPIホストの追加機能。ホストプロセスの環境変数で有効にする。初期状態は無効で、既存Drift・ホストDBの移行は不要。

| 設定 | 指定する値 |
|---|---|
| MEDIA_SERVER_COMFY_OUTPUT_DIR | ComfyUIが現在使っている出力ディレクトリ。ホストには読み取り権限を付与 |
| MEDIA_SERVER_GENERATED_LIBRARY_DIR | サービス用の書き込み可能なローカルディスク上の新規または空の専用ディレクトリ。出力元・既存メディアルート・Web配信先から分離 |
| MEDIA_SERVER_AUTH_TOKEN | 既存ホストのBearerトークン。例示値を避けて秘密の値を使用。既存ホストで初めて設定する場合は既存クライアント側にも設定が必要 |

設定後にホストを再起動する。出力元の既存ファイルも初回取り込みの対象になる。PNG・JPEG・WebPをサブフォルダまで走査し、リンク・ジャンクションを除外する。原画像のバイト列はメタデータを含めて保存する。複数の出力元ファイルが同一内容の場合は、専用ライブラリ内の原本・完了イベントは各1件になる。

ワーカーは走査終了後5秒待つ。サイズ・時刻・ファイル識別情報が2回の観測で一致し、2秒以上経過したファイルを一時コピーする。コピー中の変更、長さとSHA-256、Pillowでの画像検証・デコードを確認する。破損画像は元ファイルの変更後に再検査する。画像として既に有効なファイルを生成元が長時間停止した後に再更新した場合は、異なる内容として取り込まれる。

専用SQLiteの台帳にステージングを記録し、同一ボリューム内で原本を原子的に配置する。原本登録後に最大384×384のPNGプレビューを作成し、完了状態とイベントを同一トランザクションで確定する。中断後は次回走査で保留分を優先処理する。ステージ済みコピーが壊れていた場合は出力元からやり直す。容量不足は空きを確保すると再試行される。取り込みを停止するには両方のパス設定を外してホストを再起動する。生成ライブラリは保持される。

## 読み取りAPI
全経路に `Authorization: Bearer <token>` が必要。HTTP取得・WebSocket購読ともにファイルパスを引数にしない。

- `GET /generated/events?after=0&limit=100` は取り込み完了の一覧を昇順に返す。`items` の要素は `seq` と `mediaId`。受信処理済みの最終seqを次のafterに渡す。limitの最大値は250。
- `WS /generated/events/ws?after=0` は同じ形式で未受信分と新着を配信する。再接続時もafterを指定できる。認証ヘッダーを指定できるクライアント向け。
- `GET /generated/media/{mediaId}` は原本、末尾に `/thumbnail` を付けるとサムネイル。IDは登録済みのSHA-256。
- 初期設定エラーはホストログに記録し、新ルートを無効化する。パスや認証設定の変更後はホストを再起動する。

Phase 2の動作確認は一時ディレクトリで生成した画像が対象。実ライブラリの設定と外部公開は行わない。

## Phase 3 のギャラリー

ネイティブ版はホスト／クライアントモードの Home メニューから「生成画像」を開く。Web 版はホスト接続後、Home 上部の「生成画像」を使う。現在の接続先と認証設定を引き継ぎ、画面を開いたときに48件ずつ取得する。

一覧ではプロンプト全文検索、タグ条件（AND・OR・NOT）、期間、お気に入り、名前順・日時順を組み合わせられる。期間はWindows出力元の作成日時を使い、取得できない場合は更新日時を使う。採用した日時の種類は詳細画面に表示される。チェックボックスまたは長押しで複数選択し、「選択した画像のタグを編集」からカテゴリ・タグ名・付与／解除を確認する。

詳細画面は原寸画像、生成パラメータ、元のworkflow・API promptを表示する。標準KSampler系と、対応するguider・scheduler等を組み合わせたSamplerCustom系をノード型と接続から解析する。複数のサンプラーはそれぞれ表示する。未知の構成は埋め込み原文を保持し、画像に記録されていない項目は空欄とする。

生成専用SQLiteに解析結果・FTS5検索索引・手動タグ・お気に入りを別々に追加する。手動タグのキーは画像ID・カテゴリ・タグ名。「生成情報を再解析」は解析結果と検索索引だけを更新する。以前の取り込み済み原画像はバックグラウンドで1走査につき最大64件を索引化する。

新しい認証付きルートは `POST /generated/search`、`GET /generated/media/{mediaId}/details`、`POST /generated/media/{mediaId}/reanalyze`、`PUT /generated/media/{mediaId}/favorite?value=true`、`POST /generated/tags`。一括タグ編集は1つのトランザクションで処理し、対象に存在しないIDが含まれていれば全件を取り消す。

## Phase 4 の接続・キャッシュ・タグ編集

ネイティブ版は Home メニューまたはホスト接続失敗画面の「ローカルの画像・PDFを開く」でスタンドアロンに切り替える。端末上の画像とPDFは既存のローカルRepositoryで開く。ホストへ戻るには接続設定でモードを選び直す。Web版の生成画像はホスト接続が必要。

リモートファイルのディスクキャッシュは原本512 MiB、サムネイル64 MiB、プレビュー96 MiBを保持上限とする。転送中・閲覧中は一時的に超えることがある。接続先と認証情報でキャッシュキーを分ける。生成画像一覧では圧縮サムネイルを別途メモリに最大32 MiB保持し、上限を超える単一画像は保持しない。

生成ギャラリーは通信結果と30秒ごとの疎通確認で接続状態を表示する。生成画像の手動タグ編集は表示時の版を送信し、競合時は一括編集全体をHTTP 409で取り消す。画面で最新のタグを確認してから再編集できる。旧クライアントから版指定なしの編集も受け付け、その変更でも版が進む。

## Phase 5 のリモート生成

LAN・外出先からの認証と端末トークンの設定は [Phase 6 のプライベート接続](private_access.md) を参照。

差分同期・停止中バックアップ・復元手順は [Phase 7 の同期・バックアップ・復旧](sync_backup_recovery.md) を参照。

生成ギャラリー上部の「画像を生成」からプリセットを選び、生成設定を入力する。Flutterは認証付きFastAPIの `/generated/presets` と `/generated/jobs` を利用する。生成履歴は再接続時に取得し、表示中は3秒ごとに更新する。以前の履歴は100件ずつ追加取得できる。生成完了後、戻ったギャラリーを更新して画像を表示する。

### ホスト設定

1. Phase 2の生成ライブラリとBearer認証を設定する。
2. `server/config/comfy_presets.example.json` をホストの設定用ファイルへコピーする。Checkpoint・LoRAの `REPLACE_WITH_...` をインストール済みモデル名に置き換え、許可する名前だけを `choices` に登録する。不要なプリセットは取り除く。
3. 使用するモデルに合わせて、ComfyUIで動作確認したAPI形式のworkflowを設定する。付属例は標準KSampler・EmptyLatentImage・CheckpointLoaderSimpleを使う構成。モデルに固有のノードが必要ならそのworkflowと編集先ノードIDを登録する。
4. `MEDIA_SERVER_COMFY_URL=http://127.0.0.1:8188` と `MEDIA_SERVER_COMFY_PRESETS_PATH` に設定ファイルの絶対パスを指定し、ホストを再起動する。

プリセットの `parameters` には表示名、型、初期値、数値の上下限・刻み、文字数、選択肢と、workflowのノードID・入力名を定義する。Positive/Negative Prompt、Seed、Steps、CFG、Width/Height、Batch Size、Checkpoint、Sampler、Scheduler、LoRA名と適用強度を例に含めた。任意のノード・workflow・入力名をクライアントから送れないようにし、範囲外の値は422で拒否する。Seedの例はWebでも整数を保持できる上限を使う。実際のモデル名とworkflowはホスト管理者が確認して登録する。

### 永続化と復旧

既存の生成専用SQLiteに `generation_jobs` を追加し、設定を反映したworkflow、ComfyUIのprompt ID、状態、進捗、登録画像IDを保存する。状態は `queued`、`submitting`、`running`、`importing`、`completed`、`failed`、`cancel_requested`、`cancelled`。FastAPIのlifespanでワーカーを管理し、SQLiteの専用ロックで複数ホストプロセスからの二重実行を防ぐ。Flutter終了後もホストとComfyUIが稼働していれば処理が続く。

送信前にIdempotency-KeyをSQLiteへ保存する。同じキーと設定は同じジョブを返し、設定が違う場合は409とする。Flutter側も応答未確認の送信内容とキーを接続先ごとに保存する。「前回の送信を確認・再試行」で同じキーを再利用できる。画面やアプリを開き直しても送信内容を復元する。

ComfyUIへの `/prompt` 送信前に `submitting` を永続化する。応答を失った場合は `/queue` と `/history` 内の専用ジョブ識別子で照合し、自動的な再送はしない。古いComfyUIがprompt IDを採番する場合も照合する。オンラインで60秒経過しても送信結果や履歴が見つからなければ失敗として表示する。ComfyUI側で履歴が消失した場合は実行結果を保証できないため、ComfyUIを確認してから新しいジョブを送る。

WebSocket `/ws` で進捗を監視し、切断時はHTTP履歴取得で補完する。完了後 `/history/{prompt_id}` と `/view` で保存画像を取得し、既存のステージング・ハッシュ重複判定・サムネイル作成処理で登録する。1画像のダウンロード上限は256 MiB。登録途中の画像IDも保存し、再起動後は残りを処理する。画像検証に失敗したジョブには失敗状態を表示する。

キャンセルは未送信ジョブを即時取り消し、ComfyUIの待機ジョブは該当prompt IDのみキューから除く。古いComfyUIの `/interrupt` が全体を停止するため、実行中は終了を待ってキャンセルを確定する。`importing` 以降のキャンセルは受け付けない。ComfyUIがoutputに保存した画像は、既存のフォルダー監視によって別途ギャラリーに取り込まれる場合がある。

APIの参照元はComfyUI公式の [WebSocket利用例](https://github.com/comfyanonymous/ComfyUI/blob/master/script_examples/websockets_api_example.py) と [サーバールート実装](https://github.com/comfyanonymous/ComfyUI/blob/master/server.py)。検証は模擬ComfyUIと一時ライブラリを使用する。実GPUと実モデルでの生成はホスト設定後に確認する。
