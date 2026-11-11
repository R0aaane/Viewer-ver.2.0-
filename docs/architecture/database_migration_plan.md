# DB構造と移行手順

## 現在のデータ境界
lib/database/app_db.dart の Drift は schemaVersion 3。アプリ文書領域の PDF_Viewer/media_viewer.sqlite を使用し、app_storage_paths.dart が旧配置からの移動も扱う。

| テーブル | 主キー・用途 |
|---|---|
| MediaItems | id（Windowsのパス／Androidの文書URI）、親・表示名・種別・更新時刻 |
| Tags | tagId、(name,category) 一意。artist・series・mediaType・character・free の順序を保持 |
| MediaItemTags | (itemId,tagId)、両テーブルへの外部キー |
| FolderIndexes | folderRaw、スキャン時刻・件数 |
| FolderEntries | (folderRaw,entryId)、表示名・種別・更新時刻・ソート用名 |

初回は全テーブルと索引を作成。v1→v2でフォルダ2表、v3でフォルダ・カテゴリ別タグ・中間表両方向・フォルダ内整列の索引を追加。開く際に外部キー、WAL、busy_timeout 5000 ms を設定。AppDb.backupToFile は VACUUM INTO を使い、指定済みの出力先は置き換えるため、検証には毎回新規の出力名を使う。

server/repositories/sqlite_store.py の sqlite3 DB は別系統。media_records は media_id 主キーとパスの一意制約を持つ。tag_master、media_tag_links、indexed_folders、media_stats、media_activity、reading_progress、media_favorites、media_ratings がある。DriftのIDと相互代用しない。

## 承認後の案
1. 初回はローカル v3 を維持。生成用DBを別ファイルにし、ライブラリ固有IDとメディアIDの組で識別する。元画像ハッシュを一意にし、ファイル名・端末上のパスは識別キーにしない。
2. 生成DBに取り込み台帳、元の workflow/API prompt JSON、抽出結果、ユーザー編集、ジョブ、変更履歴を別々に保存。再解析は抽出結果のみ交換。旧ホストのタグを自動転記しない。
3. ローカル永続キャッシュが必要になった段階でのみ、Driftの新バージョンにサーバー識別子と複合主キーを持つ表を追加。既存種別の整数値・主キー・保存先を維持する。
4. 試験専用コピーを整合した SQLite バックアップから取得し、旧版ごとに移行前後の integrity_check、foreign_key_check、表件数、タグ関連集合、URI、並び順を比較。旧配置からの起動も隔離した文書領域で試す。失敗時は新機能を停止し、退避コピーを隔離環境に復元して確認する。
5. 生成ライブラリは不変の原画像とDBスナップショットに記録したハッシュ目録を一組にして退避。削除・回収を退避中は保留し、別ディレクトリに復元して全ハッシュ・タグ・ジョブ状態を照合する。
