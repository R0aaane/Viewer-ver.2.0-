# メインPCから直接配信する自動更新

## 調査結果

旧 `host_auto_update.ps1` はホストでGit取得・pip install・Flutter Web/Windowsビルド・再起動を行っていた。APIは `server.main:app`（FastAPI/Uvicorn）で、同一ポートからWebを配信する。WindowsアプリはAPIの実行に不要。ホスト報告では稼働版1.0.210+220、ポート8090、Python 3.13、設定は `D:\PdfViewerHost\host.env` / `agent.json`。これらはホストからの報告であり、この開発PCからの実機確認ではない。

SQLiteはWALを使用し、起動時にスキーマ初期化・再走査・統計補完・タグ別名移行がある。新旧APIを同じ本番DBに同時起動しない。既存のPDF・DB・設定は配布物へ含めず、現在の絶対パスを引き継ぐ。

## 新方式

1. メインPCの `main_pc_deploy.py` が60秒ごとに `git ls-remote` で対象ブランチのGitHub側のSHAを確認する。SourceTree/Codex/CLIのどこからpushしても検知する。ローカルコミットだけでは配信しない。短時間の複数pushは最新SHAを優先する。
2. 専用bare repositoryへfetchし、そのSHAの必要ソースだけを新しい作業フォルダーへ展開する。開発中のcheckout・未コミット変更・本番データには触れない。取得中にブランチが進んだ場合は最新SHAでやり直す。
3. Python依存wheel取得、Python/Flutterテスト、生成Dartコード作成、Web Releaseビルド、ZIP作成をメインPCで行う。バックエンドはPythonコードと完成済みwheelで配布する。
4. Windows版は `buildWindows: true` の場合だけメインPCでビルドする。通常はfalse。Windows成果物はメインPCの該当ビルドフォルダーに保持し、ホストへ送らない。Android APKの既存配布API・保存済みファイルは維持するが、この経路ではAPKをビルドしない。
5. SFTP（SSH鍵認証・ホスト鍵検証）でLAN/Tailscale経由のinboxへ転送する。ZIPを一時名から確定名へrenameし、最後にJSON完了通知をrenameする。転送途中の.partはホストが無視する。GitHub Releaseは使わない。
6. ホストはハッシュ・許可パス・Python版・データ互換epoch・ソースSHAを検証する。別フォルダーへ展開し、wheelからvenvをオフライン作成する。コンパイラは使わない。DBの整合性あるコピーで隔離起動検証する。この間、旧APIは稼働する。
7. 検証後だけ旧APIを正常停止し、新APIのヘルスとWebバージョンを確認する。失敗時は旧コード・旧venvへ戻る。完全無停止ではなく、再起動・起動時処理の時間だけ停止する。長時間転送やバックグラウンドダウンロードは切り替えの影響を受け得る。
8. メインPCはSFTPでホストの稼働SHA・適用状態・最終更新時刻を読み戻す。転送済みと適用済みを区別し、古い応答や異なるSHAを成功扱いしない。

`.github/workflows/host-release.yml` は削除した。この変更をpushした後、この仕組みはGitHub Actionsや有料runnerを使わない。GitHubはソース管理とブランチSHA取得だけに使う。既に走っている旧workflowがある場合はGitHub側で停止・無効化する。

## 中断・再試行・ログ

- `main-state.json` に対象SHA・配信ID・転送済み状態・ホスト確認結果を保存する。
- `jobs/<SHA>/build.json` に成功済み工程とZIPのハッシュを保存する。成功済みビルドを再実行せず、中断工程から再試行する。完了記録を書ける前に電源断した工程は再実行する。
- ビルド中の新pushは転送前に再確認し、古い成果物を送らない。転送開始後の新pushは次の監視で扱う。
- 完了通知がホストにあれば、応答喪失・再起動後も同じZIPを再転送しない。未完成の転送は先頭からやり直す。
- ファイルロックで多重起動を防ぎ、Windows Job Objectで監視プロセス終了時にそのビルド子プロセスも終了させる。
- メイン側エラーは既定300秒後に再試行する。ホスト適用失敗版は隔離し、同じ版の適用ループを防ぐ。修正版の新コミットをpushする。
- メインPCのログ: `main-agent.log`、`jobs/<SHA>/build.log`。
- ホストのログ: `agent.log`、`server.log`、`report/status.json`、既存data配下の `host_update_status.json`。
- ホストは確定後も監視し、プロセス終了または3回連続のヘルス失敗時に旧版へ戻す。初回には旧版がないため旧起動方式を保管する。

## 接続とPythonの初回準備

1. ホストのLAN/Tailscaleホスト名・SSHユーザー・ポートを確定する。Windows OpenSSH Serverと公開鍵認証を設定する。インターネットへのポート公開は不要。LAN/Tailscale内のメインPCからだけ接続できるようにする。
2. メインPCのタスク実行アカウントからGitHubへのSSH認証とホストへのSFTP鍵認証が対話入力なしで使えることを確認する。SourceTree専用の鍵設定だけではタスクから使えない場合がある。
3. ホスト鍵のfingerprintをホスト側で照合してknown_hostsへ登録する。自動処理はStrictHostKeyChecking=yesを強制する。秘密鍵・トークンはGitへ登録しない。
4. SFTPアカウントはinboxへの書込、reportへの読取だけを許可し、PDF・DB・host.env・エージェント本体・releasesへの書込権限を与えない。ホストAPI実行アカウントは既存データを操作できる別アカウントを推奨。配布ZIPは実行コードなので、配信鍵は開発者相当の信頼で管理する。
5. メインPCのビルド用PythonとホストのPythonを同じメジャー・マイナー版のx64に揃える。3.13ホストならメインPCにも3.13を用意し、設定でその実行ファイルを指定できる。検証済みローカル環境は3.10。3.13の依存wheel・テストは初回ビルドで確認する。異なる版のZIPはホストが拒否する。

## ホスト側

既存host.envの正しい保存先・認証・ポート8090を引き継ぐ。DATA_DIR、DB_PATH、THUMBS_DIR、MEDIA_ROOTS、XVIEWER_SAVED_IMAGES_DIRはMEDIA_SERVER_接頭辞を持つ既存設定キーを使い、絶対パスでreleases/inbox/reportの外を指定する。PDF・DBを移動する必要はない。

既存agent.jsonのenvFile・稼働設定は維持する。旧repository/tokenEnvは不要となり無視される。ホストのプロジェクトルートで管理者PowerShellから登録する。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Not project root' }
.\tool\install_host_release_task.ps1 `
  -InstallRoot D:\PdfViewerHost `
  -EnvFile D:\PdfViewerHost\host.env `
  -Python 'C:\実際のPythonパス\python.exe'
```

タスク実行アカウントの資格情報を入力する。inbox/reportは設定検証時に作成される。SFTPから見えるWindowsパスは通常 `/D:/PdfViewerHost/inbox` だが、SFTPのルート設定によるため実際に確認する。登録直後は新サーバーを開始しない。

## メインPC側

1. `tool/main-deploy.example.json` を、例として `D:\PdfViewerBuild\main-deploy.json` へコピーする。
2. repositoryに開発checkoutのルート、remoteにGitのremote名、branchに配信ブランチを指定する。現在のremote名は `Viewer(ver.2.0)`、ブランチは `feature_hitomi`。GitHub URLはremote設定から読む。
3. pythonにホストと同じ版のビルド用Pythonを指定する。SSH準備前は例のまま `transport: null` でビルド・監視できる。完成後は `awaiting_transport` で保持する。buildWindowsは通常false。
4. メインPCのプロジェクトルートから実行する。

```powershell
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Not project root' }
.\tool\install_main_deploy_task.ps1 `
  -InstallRoot D:\PdfViewerBuild `
  -ConfigFile D:\PdfViewerBuild\main-deploy.json
Start-ScheduledTask -TaskName PdfViewerMainDeploy
```

タスクはOS起動時に開始し、ログインなしで動作する。実行アカウントのPATHからgit/flutter/dart/sftpを利用できるようにする。設定検証だけではネットワーク認証を保証しない。登録前に `python tool/main_pc_deploy.py --config ... --once` で一巡実行することもできる。

状態確認:

```powershell
python D:\PdfViewerBuild\main_pc_deploy.py --config D:\PdfViewerBuild\main-deploy.json --status
```

phase=awaiting_transportは接続設定待ち、awaiting_applyは転送済み、appliedは稼働SHA確認済み、apply_failedはホスト適用失敗またはロールバック。hostErrorとホストのupdatedAtも確認する。以前のapplied記録だけで現在の稼働を判断しない。

SSH準備後は監視タスクを停止し、設定のtransportを下記に置き換えて再開する。接続設定だけの変更では完成済みビルドを再利用する。鍵ファイル不足などの設定不備でもビルドを先に行い、転送は保留する。設定の再読込には監視の再起動が必要。

```json
"transport": {
  "target": "実際のSSHユーザー名@100.100.18.16",
  "port": 22,
  "identityFile": "C:\\Users\\実際のユーザー\\.ssh\\pdfviewer_deploy",
  "knownHostsFile": "C:\\Users\\実際のユーザー\\.ssh\\known_hosts",
  "inbox": "/D:/PdfViewerHost/inbox",
  "status": "/D:/PdfViewerHost/report/status.json"
}
```

Windows OpenSSHの初期設定は [host-openssh.md](host-openssh.md) を参照。

## 初回切り替え・復旧

メインPCでビルド・転送まで進め、ホストinboxにZIPと完了JSONが揃ったことを先に確認できる。準備ができるまで旧APIを停止する必要はない。ただしpushに反応する旧更新ループは先に停止し、ホストビルドを防ぐ。

準備完了後に旧更新タスクを無効化し、実行中の旧PowerShellループと旧APIを停止する。Windowsアプリから旧ループが再起動しないよう旧ホスト起動機能を併用しない。SQLite/WALを考慮したバックアップを確認し、`Start-ScheduledTask -TaskName PdfViewerHostRelease` で開始する。

認証付き/health、Web、既存PDF、タグ・既読情報、アップロード・ダウンロードを確認する。初回失敗時は新方式を停止し、保管した旧起動方法へ戻す。旧checkout・データ・設定を削除しない。

新エージェントとAPIの保守停止は、ホストで次を実行し、タスク終了とAPI停止を確認する。

```powershell
python D:\PdfViewerHost\host_release_agent.py --config D:\PdfViewerHost\agent.json --stop
```

処理中の準備が終わってから正常停止するため即時停止ではない。停止待ちが終わらない場合は別APIを起動せずログを調べる。通常更新の停止・再起動はエージェントが行う。

自動ロールバックはコード・依存関係を戻す。更新後の書込を失わないようDBを古いコピーで自動上書きしない。dataEpoch: 1では旧版との後方互換性を守る。破壊的なDB変更はepochを変えて通常更新から除外し、別途計画移行する。

エージェント本体は自動上書きしない。各PCの保守時に導入スクリプトで更新する。ログ・jobs・古いreleases・転送失敗時の孤立ファイルは自動削除しない。容量を監視し、両タスク停止中にcurrent/previous/処理中以外だけを整理する。

参考: [Git ls-remote](https://git-scm.com/docs/git-ls-remote)、[OpenSSH SFTP](https://man.openbsd.org/sftp.1)、[Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)。
