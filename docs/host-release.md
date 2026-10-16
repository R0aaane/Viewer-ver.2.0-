# ホストの自動更新

## 調査結果と採用方式

現在の `tool/host_auto_update.ps1` は60秒間隔でGitを取得し、更新時にAPI・Windowsアプリを停止して、pip install、Flutter Web・Windows（指定時はAndroid）ビルド、再起動を行う。ビルド失敗時の復旧・稼働確認がない。Windowsアプリからも同じスクリプトが起動される。

APIは `server.main:app`（FastAPI / Uvicorn）。同じポートで `build/web` を配信する。SQLiteはWALで、起動時にスキーマ初期化、インデックス再走査、統計補完、タグ別名の移行を行う。WindowsアプリはAPI運用に必須ではないが、アプリ経由の起動ではSharedPreferencesから保存先・認証設定を渡している。この設定を移行せず `.env` だけで起動すると別のDBを参照する恐れがある。

採用方式は **Actionsでビルド → GitHub Release → ホストの常駐エージェントが取得 → 起動検証 → 短時間再起動**。同じSQLiteへ新旧APIを同時起動するBlue/Green方式は採用しない。ダウンロード・依存関係展開・DBコピーによる事前検証中は旧APIを稼働させる。切り替えではUvicornを正常終了させ、DB接続の解放後に新版を起動する。完全無停止ではなく、再起動・起動時処理に応じた停止時間がある。長時間のPDF送信・ダウンロードは切り替え時に中断される場合がある。

## 自動処理

- `.github/workflows/host-release.yml` は配信ブランチへの対象変更のpush、または手動実行で起動する。既定はリポジトリのdefault branch。別ブランチを使う場合はRepository variable `HOST_RELEASE_BRANCH` を設定する。
- Windows runner / Python 3.10 x64 / Flutter 3.41.5でPython・Flutterテスト、Web Releaseビルドを実行する。生成DartコードもCIで作成する。
- 配布内容はサーバーPythonコード（vendorを含む）、Web、タグ別名定義、requirements、Windows用wheelだけ。Windowsアプリ・Android APKはこのサーバー更新経路でビルドしない。既存APK配信APIと保存済みAPKは維持する。APKを更新する場合は従来の手動アップロード等を別途利用する。
- Webに元から含まれる `env.json` は公開クライアント設定（Xのclient ID / redirect URI）として維持する。秘密情報はこのファイルに入れず、ホスト専用のenvファイルに置く。
- `host-<run_number>-<run_attempt>` のReleaseへZIPとSHA-256をアップロードし、全ファイルが揃ってから公開する。他のアプリReleaseのlatest指定には影響させない。
- ホストは60秒ごとにReleaseを確認（トークンなしではAPI制限を避けるため120秒以上）。ZIPと内部ファイルのハッシュ、許可パス、データ互換epochを検証する。ホストではGit / Flutter / コンパイラ不要。Python venvへ配布済みwheelをオフラインインストールする。
- 新版を本番DBのSQLite backupコピーと隔離した一時保存先で起動。APIとWebの版を確認する。公開ポートの切り替え後も連続したヘルスチェックを通過してからstate.jsonを確定する。
- 新版の起動失敗時は旧コードと旧venvを起動する。失敗版を記録して同じ版への更新ループを防ぐ。更新途中の電源断では最後に確定した版に戻る。初回導入には旧版がないためロールバックできない。
- 確定後も定期監視し、プロセス終了または3回連続のヘルス失敗で旧版へ戻す。旧版のない初回導入では同じ版を再起動する。
- `/host-update/run` はエージェントに再確認を要求する。`/host-update/status` は従来の保存先で状態を返す。

## 初回移行（ホストで一度だけ）

1. GitHub側へ変更をpushし、配信ブランチのworkflow成功と `host-...` Release公開を確認する。ここではpush・公開・本番変更は自動実行していない。
2. 現在実際に使っているPDF、DB、サムネイル、X画像、認証トークン、ポートを確認する。Windowsアプリが使用しているAppData配下のDBと、リポジトリ直下のdataを混同しない。DB・設定のバックアップを取得する。
3. リポジトリやreleasesの外に、例えば `D:\PdfViewerHost\host.env` を保存する。値は現在の運用値を使う（以下は例）。エージェントはこのファイルを書き換えない。相対パスは禁止。

```dotenv
MEDIA_SERVER_HOST=0.0.0.0
MEDIA_SERVER_PORT=8000
MEDIA_SERVER_DATA_DIR=D:\PdfViewerData
MEDIA_SERVER_DB_PATH=D:\PdfViewerData\metadata.db
MEDIA_SERVER_THUMBS_DIR=D:\PdfViewerData\thumbs
MEDIA_SERVER_MEDIA_ROOTS=D:\PDF;E:\Library
MEDIA_SERVER_XVIEWER_SAVED_IMAGES_DIR=D:\Xsaved_images
MEDIA_SERVER_AUTH_TOKEN=既存の値
MEDIA_SERVER_STARTUP_RESCAN=true
MEDIA_SERVER_CORS_ORIGINS=*
```

4. Python **3.10 x64** をホストにインストールする。private repositoryなら、このタスクの実行アカウントの環境変数 `GITHUB_TOKEN` に対象repositoryのContents read権限を持つトークンを設定する。トークンは配布物・JSONに保存しない。タスク開始時に環境変数が反映されることを確認する。
5. プロジェクトルートで管理者PowerShellから実行する。タスク実行アカウントの資格情報がWindowsの登録ダイアログで必要になる。PDF/DB/設定/インストール先へのアクセス権とネットワークアクセスを付与する。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Not project root' }
.\tool\install_host_release_task.ps1 `
  -InstallRoot D:\PdfViewerHost `
  -EnvFile D:\PdfViewerHost\host.env `
  -Repository 'R0aaane/Viewer-ver.2.0-'
```

6. 既存の `PdfViewerHostAutoUpdate` タスク（独自名ならその名前）を無効化し、既存PowerShell更新ループと旧APIを正常停止する。Windowsアプリのホスト起動機能は使用しない。同じポートで旧APIが稼働中の場合、新エージェントはそのプロセスを強制終了しない。
7. `Start-ScheduledTask -TaskName PdfViewerHostRelease` で開始する。以後はOS起動時に自動開始し、ログインなしで稼働する。初回はダウンロード・環境作成分の停止時間が必要。
8. 認証付き `/health`、ブラウザー表示、既存PDF閲覧、タグ・既読情報、ダウンロードを確認する。`agent.log`、`server.log`、保存先の `host_update_status.json` を確認する。失敗した場合は新タスクを停止し、旧起動方法へ戻す（元のcheckoutとデータは残る）。

## 復旧と互換性

`agent.json` は運用設定、`state.json` は確定版・旧版・失敗版の管理情報、`releases` は版ごとのコードとvenv。データ・設定をreleasesに置かない。自動削除は行わないため、容量を監視し、停止中にcurrent/previous以外の不要版と古いログを整理する。

自動ロールバックは **コードと依存関係** の復帰であり、DBを古いコピーで上書きしない。更新後の書き込みを失わないためである。`dataEpoch: 1` の配布では旧版でも読めるスキーマ・データの後方互換性を守る。破壊的なDB変更はepochを変更し、別途バックアップと計画移行を行う。epochが違う配布は現エージェントが拒否する。epoch宣言だけで互換性が証明されるわけではないため、スキーマ変更のレビューは必要。

bootstrap（`host_release_agent.py` / `host_runtime.py`）は自動で上書きしない。安定した復旧経路を維持するため、これらの更新は保守時にタスクとAPIを停止してコピーする。通常のAPI/Web更新は完全自動。

GitHub Releaseへの書き込み権限が配布の信頼境界になる。SHA-256は破損検出であり署名ではない。配信ブランチ保護とRelease immutabilityを推奨。初回登録後に同名ブランチを切り替えない。別のリポジトリへ切り替える際はstateを移行計画に含める。

参考: [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)、[Release immutability](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)、[Uvicorn deployment](https://www.uvicorn.org/deployment/)。
