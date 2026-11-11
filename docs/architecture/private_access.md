# Phase 6 のプライベート接続

## 実装環境と接続先

WindowsホストのTailscale 1.92.3でServeを有効化した。接続URLは `https://toybox.tailcb6ddc.ts.net/`、転送先は `http://127.0.0.1:8090`。自宅LAN・外出先のどちらでも、端末を許可されたtailnetへ接続して同じURLを使う。ホストPCとTailscaleサービス、ホストAPIの稼働が必要。

内蔵FastAPIの初期待受はlocalhost。更新用ワーカーからの再起動も同じ待受を引き継ぐ。HTTPとWebSocketは実際の接続元を確認し、初期設定ではloopbackとTailscaleのIPv4・IPv6範囲を受け付ける。Uvicornは `--no-proxy-headers` で起動する。逆プロキシの転送先がloopbackでも、転送ヘッダーを持つ接続をローカル管理操作として扱わない。

Tailscale Serveはtailnetのアクセス制御に従う。利用端末・ユーザーにこのホストの443番ポートへの接続を許可する。設定の参照先は [Tailscale Serve公式ガイド](https://tailscale.com/docs/features/tailscale-serve) と [CLIリファレンス](https://tailscale.com/docs/reference/tailscale-cli/serve)。

## ホストの起動

1. 新しいWindows Releaseを起動し、接続設定でホストモードを選ぶ。
2. 「認証トークン」の鍵ボタンでホスト用トークンを生成し、設定を保存する。既存トークンは保護ストレージへ移行する。
3. ポート8090でホストAPIを起動する。ホスト状態に検出したTailscale HTTPS URLを表示する。
4. クライアントには端末別トークンを発行し、接続設定にURLとトークンを入力する。

別のホスト・ポートでServeを設定する場合は、管理者PowerShellをプロジェクトルートで開いて実行する。

```powershell
.\tool\configure_private_access.ps1 -Port 8090
.\tool\configure_private_access.ps1 -Port 8090 -Apply
```

最初のコマンドで設定内容を確認できる。既存の別サービスやFunnel設定がある場合は上書きを止める。Serveの許可が必要な場合は、コマンドが表示するTailscale管理画面で有効化する。

## 端末別トークン

既存のBearerヘッダーを使用する。ホスト用トークンは既存の管理操作に対応し、`pv1.`で始まる端末用トークンは端末ごとに失効できる。端末用トークンをホスト用欄へ入力しても失効を迂回できない。アプリケーション更新のアップロードとホスト更新スクリプト実行にはホスト用資格情報が必要。

ホストのプロジェクトルートで実行する。発行時のトークンは一度だけ表示するため、対象端末へ安全に転送する。

```powershell
.\tool\manage_device_tokens.ps1 -Action issue -Value 'my-phone'
.\tool\manage_device_tokens.ps1 -Action list
.\tool\manage_device_tokens.ps1 -Action revoke -Value '<一覧の端末ID>'
```

ラッパーは内蔵ホストと同じ、WindowsのDocuments配下 `PDF_Viewer\host_api` を既定にする。`MEDIA_SERVER_DATA_DIR` があればそれを使用する。手動起動したサーバーや別データディレクトリの場合は `-DataDir '<実際のデータディレクトリ>'` を指定する。Python CLIでは `python -m server.manage_devices --data-dir '<同じディレクトリ>' issue my-phone` を使える。

サーバーは `device_tokens.sqlite` に端末名・ID・発行日時・失効日時・トークンのSHA-256を保存する。失効はHTTPの次回要求と、接続中の生成イベントWebSocketに反映する。最後の端末を失効しても認証は必須。認証未設定のAPIは503を返す。

## 資格情報とファイル操作

ネイティブ版は既存のflutter_secure_storageを使用する。旧SharedPreferencesのトークンは保護ストレージへの保存成功後に削除する。Web版はページを開いている間のメモリに保持し、再読み込み後は再入力する。旧Web保存トークンは削除し、URLのtokenパラメータは読み取らずアドレスから除去する。

別Originからの要求を拒否し、明示的に許可したOriginと同一ホストからの要求を受け付ける。認証ヘッダー付き応答は `Cache-Control: no-store` とする。接続元・Originの判定は通常HTTPとWebSocketに適用する。

遠隔からの名前変更・削除・アップロード・整理・再スキャンは、設定済みライブラリ内のパスへ制限する。パスの正規化で親参照・名前の似た別フォルダー・ライブラリ外へのシンボリックリンクを拒否する。一括削除は全対象を検証してから変更する。ダウンロードのCookieファイルやURLリストなどホスト上のファイル指定は、ローカルのホスト管理操作で行う。既存の削除・一括操作の確認ダイアログを利用する。

ComfyUIはPhase 5のlocalhost接続とホスト登録プリセットを使用する。クライアントはFastAPIへ生成を依頼する。

## 検証

端末発行・個別失効・最後の端末失効後の認証、公開IPや転送ヘッダーによる制限回避、異なるOrigin、パス逸脱、一括変更前の検証をテストする。既存のファイル操作・検索・生成処理も回帰テストする。

Windowsではアプリの資格情報と異なる専用テストキーを使い、実際の保護ストレージへの保存・読込・削除を確認する。

実際のServe URLでも、一時ライブラリと一時トークンを使い、HTTPSで401／200、失効後の401と接続中WebSocket切断を確認した。この検証はホストPCからの接続。スマートフォンの携帯回線からの確認は別途必要。

再検証は8090番ポートが空いている状態で実行する。

```powershell
$env:MEDIA_SERVER_TEST_TAILNET_URL = 'https://toybox.tailcb6ddc.ts.net'
.\.venv\Scripts\python.exe -m unittest server.tests.test_tailnet_access
```
