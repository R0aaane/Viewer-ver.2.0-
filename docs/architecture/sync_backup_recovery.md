# Phase 7 の同期・バックアップ・復旧

## 差分同期

生成専用SQLiteと既存の索引SQLiteに、追加テーブル `sync_meta`、`entity_versions`、`sync_changes` を作成する。既存テーブルとIDを使い、変更と履歴を同一トランザクションで保存する。旧DBの既存画像には初期スナップショットの履歴を付ける。履歴は削除せず、APIでは最大250件ずつ返す。

認証付きの `GET /generated/changes` と `GET /sync/changes` は `after`、`epoch`、`limit` を受け付け、`cursor`、`epoch`、`items`、`hasMore`、`resetRequired` を返す。変更には取り込み、タグ、お気に入り、名前変更、削除、復元を含む。既存タグマスターの名称変更も関連画像の変更として記録する。

Flutterは接続先・資格情報の組み合わせごとにカーソルと世代を保存する。生成ギャラリーは表示中5秒ごとに取得し、1回の確認は最大8ページに制限する。選択中の画像がある場合は一覧の自動再取得を保留する。既存RemoteMediaRepositoryはフォルダー一覧・ページ取得時に差分を確認し、メタデータキャッシュとパス対応を無効化する。復元世代が変わるとディスクキャッシュの名前空間も切り替える。

生成ギャラリーでは画像詳細の「画像の操作」から表示名変更、削除済みへの移動、復元を行う。原本はハッシュ名で保持し、表示名と削除状態を別テーブルへ保存する。再解析で手動タグ・表示名・削除状態を引き継ぐ。

生成画像のメタデータ編集・お気に入りは表示時の版を照合し、409のときは再取得してから編集する。表示時の世代も送るため、バックアップ復元後に同じ版番号へ戻っていても古い編集を拒否する。既存タグAPIは読取応答に `version` と `epoch` を追加し、変更要求の `expectedVersion` と `expectedEpoch` を同一トランザクション内で照合する。旧クライアントから版指定が省略された要求も受け付けるため、競合検出には対応クライアントが必要。

## ホストのバックアップ

Windowsホストの停止中にDBとファイルをまとめて取得する。ホストは起動中、データディレクトリの共有メンテナンスロックを保持する。バックアップ・修復は排他的なロックを取得し、起動中なら処理を中止する。旧版ホストや手動ツールも停止してから実行する。

バックアップ対象は次のとおり。

- 既存索引DB、生成専用DB、端末トークンのハッシュ・失効情報
- 設定済みメディアルートの画像・PDF等、登録済み生成原本とサムネイル
- PDF編集の復元用履歴、X画像保存先
- プリセットのworkflow JSON、ジョブ内のworkflowと生成情報、ホスト設定

ホスト用Bearerトークンは設定スナップショットから除外する。バックアップ全体はWindows DPAPIで暗号化し、ファイルごとの識別子・連番・終了マーカーとSHA-256で欠落・入替えを検証する。処理中のメモリ使用は画像全体を読み込まず1 MiB単位とする。

**復号は原則として同じPC・同じWindowsユーザーの資格情報が必要。** WindowsプロファイルやDPAPI鍵を失う障害への備えは、Windows側のプロファイル・システムバックアップにも依存する。暗号化方式の根拠はMicrosoftの [CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata) と [CryptUnprotectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata)。

新バージョンのホストを一度起動すると、秘密情報を除いた実際の保存先を `host_settings.json` に記録する。その後ホストを停止し、プロジェクトルートで実行する。

```powershell
.\tool\backup_host.ps1 -Action create -Destination 'E:\Backups\pdf-viewer-20261111'
```

ラッパーのデータディレクトリは内蔵ホストと同じDocuments配下 `PDF_Viewer\host_api`。手動ホストには `-DataDir '<実際のデータディレクトリ>'` を指定する。バックアップ先はデータ・メディアと別の新規ディレクトリを選ぶ。ファイルが変化した場合、原本が欠損・破損している場合、公開途中の画像がある場合、容量不足の場合は完成版を公開しない。

## ホストの復元

現在のデータを上書きせず、新しいディレクトリへ復元する。

```powershell
.\tool\backup_host.ps1 -Action restore `
  -Source 'E:\Backups\pdf-viewer-20261111' `
  -Destination 'E:\Recovery\pdf-viewer-20261111'
```

全ファイルのハッシュとSQLiteの整合性を検証し、既存索引DBのパスを復元先メディアルートへ付け替える。同期世代を更新し、復元した端末トークンは全件失効させる。未完了ジョブは失敗状態にして、ComfyUIを確認するまで自動再送を防ぐ。途中のエラーでは復元先の完成ディレクトリを作らない。

復元後は `restored_settings.json` の値を環境変数へ設定して、復元先のデータを使うサーバーを手動起動できる。以下は同じPowerShell内で実行する例。

```powershell
$restored = Get-Content 'E:\Recovery\pdf-viewer-20261111\restored_settings.json' -Encoding UTF8 | ConvertFrom-Json
foreach ($property in $restored.PSObject.Properties) {
  [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
}
$env:MEDIA_SERVER_AUTH_TOKEN = ''
.\tool\manage_device_tokens.ps1 -Action issue -Value 'my-phone' `
  -DataDir 'E:\Recovery\pdf-viewer-20261111\data'
.\.venv\Scripts\python.exe -m uvicorn server.main:app --host 127.0.0.1 --port 8090 --no-proxy-headers
```

端末は新しく発行したトークンで接続し、フォルダーを選び直す。既存のTailscale Serveは同じ8090番ポートへ転送できる。生成はプリセットとComfyUIの状態を確認してから再度有効化する。内蔵ホストが使うデータと復元先は別ディレクトリなので、接続するサーバーの保存先を確認する。

## 既存Drift DBのバックアップ

ローカルアプリのDBは既存の設定画面から取得する。エクスポートはSQLiteの `VACUUM INTO` でWALを含むスナップショットを作成する。復元前にコピーの整合性・テーブル・スキーマ版を検証し、接続を閉じてから置き換える。置換前のDBを `.previous_<日時>` として保持する。復元後はアプリを再起動する。ホストバックアップとローカルDrift DBバックアップはそれぞれの所有データを対象とする。

## 障害時の動作

- ホスト再起動時は既存取り込みジャーナルとジョブIDを照合し、応答不明の生成を再送しない。
- ComfyUI停止・ネットワーク切断時は既存ジョブの照合と差分取得を再試行する。ローカル閲覧はPhase 4の既存Repositoryを使う。
- SQLiteの一時ロック・容量不足にはAPIが503と `Retry-After` を返す。生成ワーカーも再試行する。
- 画像登録中の容量不足は `importing` を保ち、空き容量を確保してから登録を続ける。
- 未完了コピーは取り込みジャーナルで復旧し、不完全な原本はバックアップ完成前に拒否する。
- 待機・実行の上限は既定6時間。`MEDIA_SERVER_GENERATION_TIMEOUT_SECONDS` で60秒から7日の範囲へ変更できる。上限後もComfyUIの他ジョブを中断しないため、ComfyUI側の実行状態を確認する。

ホストを停止して修復する場合は次を使う。

```powershell
.\tool\backup_host.ps1 -Action repair
```

既存索引を再スキャンし、生成原本のハッシュを確認してサムネイル・派生情報を再生成する。手動タグ・表示名・お気に入りは保持する。原本自体が破損している場合は、検証済みバックアップから回復する。

## 検証範囲

実在する `data/metadata.db` を読み取り専用でコピーし、コピー側だけで追加マイグレーションと件数保持を確認した。テストは一時データで、差分ページング、再接続、復元世代、競合とロールバック、暗号化往復、破損・容量不足での公開中止、サムネイル修復、WAL復元を確認する。Windows画面でも表示名変更・削除・復元を検証する。30,000画像の性能測定はこのPhaseでは実施していない。
