# Tailscale経由のWindows OpenSSH準備

接続先は `100.100.18.16`。ホスト側Codexで以下を実際のユーザー名・権限に合わせて準備する。本番APIの停止は不要。既存sshd設定を丸ごと上書きしない。

1. ホストの管理者PowerShellで `Get-WindowsCapability -Online -Name OpenSSH.Server*` を確認する。未導入なら `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` で導入し、`Set-Service sshd -StartupType Automatic`、`Start-Service sshd` を実行する。
2. 配信用の非管理者ローカルユーザーを用意する。inboxへの変更権限、reportへの読取権限を付与し、PDF・DB・設定・コードへの書込権限を付けない。既存Usersグループ等からの継承権限も検査する。APIの実行ユーザーは別にする。
3. Windows FirewallのOpenSSH受信規則とTailscaleのアクセス制御を確認し、22番への接続元をメインPCのTailscale IPに絞る。メインPCで `tailscale ip -4` を実行してIPを確認する。公開インターネットへのポート開放はしない。
4. メインPCの監視実行ユーザーで `ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\pdfviewer_deploy"` を実行する。既存鍵は上書きしない。パスフレーズを付ける場合はWindows ssh-agentへ登録し、タスク実行ユーザーで再起動後も非対話認証できることを検証する。パスフレーズを設定JSONやスクリプトへ保存しない。
5. 公開鍵 `.pub` の1行だけをホストの配信ユーザーの `.ssh\authorized_keys` に追記する（UTF-8、既存鍵を保持）。秘密鍵はホストへコピーしない。鍵ファイルの書込権限を本人・SYSTEM・管理者に制限する。管理者アカウントでは配置先が異なるため、この手順では非管理者を使う。
6. ホストの `C:\ProgramData\ssh\sshd_config` の末尾に、実際のユーザー名に限定した以下のブロックを設定する。既存Matchブロックとの重複を確認する。

```text
Match User pdfdeploy
    AuthenticationMethods publickey
    PasswordAuthentication no
    ForceCommand internal-sftp
    AllowTcpForwarding no
    PermitTTY no
```

`pdfdeploy` は例。`sshd.exe -t` で構文検査してから `Restart-Service sshd` を実行する。SFTP専用アカウントのため対話シェルは使わない。NTFS権限で読書き対象を制限する。

ホストで `ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub` を実行してfingerprintを確認する。メインPCで初回 `sftp -i "$env:USERPROFILE\.ssh\pdfviewer_deploy" pdfdeploy@100.100.18.16` を実行し、表示されたホスト鍵のfingerprintを照合して登録する。異なれば登録せず原因を確認する。

SFTPで `/D:/PdfViewerHost/inbox` と `/D:/PdfViewerHost/report` が見えることを確認する。inboxへの無害なテストファイルのput/rename、reportのgetを確認し、本番データへは書き込まない。その後 `-oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes` を加えて無入力で接続できることを確認する。タスクと同じユーザーで行う。

最後にメイン側のmain-deploy.jsonへ接続先・秘密鍵のパス・known_hostsのパスを設定し、監視を再開する。秘密鍵の内容をチャットやGitへ貼らない。ホストの更新エージェントは初回移行手順が済むまで起動しない。

参考: [Microsoftの鍵認証手順](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)、[Windows OpenSSH設定](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration)。
