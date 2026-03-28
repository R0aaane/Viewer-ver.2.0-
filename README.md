# PDF Viewer Remote Metadata + Media Server

このリポジトリには、既存の Flutter 製 PDF / 画像ビューワー向けに次の最小構成を追加しています。

- FastAPI ベースのリモートメタデータ API
- PDF / 画像本体を配信するメディア API
- Flutter 側の `MediaRepository` 切替実装
- リモートモード時のグリッド / 詳細画面連携

ローカルモードでは従来どおりファイルシステムから読み込み、リモートモードでは HTTP API 経由でメタデータ取得とメディア配信を行います。

## 追加した主なファイル

### サーバー側

- `requirements.txt`
- `server/main.py`
- `server/core/config.py`
- `server/core/errors.py`
- `server/core/logging.py`
- `server/models/dto.py`
- `server/repositories/sqlite_store.py`
- `server/services/auth_service.py`
- `server/services/media_index_service.py`
- `server/services/media_stream_service.py`
- `server/services/metadata_store.py`
- `server/services/thumbnail_service.py`
- `server/api/routes_health.py`
- `server/api/routes_tags.py`
- `server/api/routes_search.py`
- `server/api/routes_actions.py`
- `server/api/routes_media.py`
- `server/.env.example`
- `data/.gitkeep`
- `data/thumbs/.gitkeep`

### Flutter 側

- `lib/services/remote_media_api_client.dart`
- `lib/repository/remote_media_repository.dart`
- `lib/repository/mediaRepository.dart`
- `lib/repository/repositoryFactory.dart`
- `lib/main.dart`
- `lib/scene/gridGallery.dart`
- `lib/scene/detailImage.dart`

## サーバー構成

### 使用技術

- Python
- FastAPI
- uvicorn
- Pydantic v2
- SQLite
- Pillow
- pypdfium2

### 保存データ

SQLite には最低限次の情報を保持します。

- `media_records`
  - `media_id`
  - `folder_raw`
  - `relative_hint`
  - `display_name`
  - `full_path`
  - `kind`
  - `mime_type`
  - `size_bytes`
  - `modified_at`
  - `modified_epoch_ms`
  - `etag`
  - `is_deleted`
- `tag_master`
  - `tag_id`
  - `name`
  - `category`
  - `normalized_name`
- `media_tag_links`
  - `media_id`
  - `tag_id`
- `indexed_folders`
  - `folder_raw`
  - `normalized_folder_raw`
  - `display_name`
  - `last_scanned_at`

### mediaId 方針

サーバー側では Flutter の `MediaIdResolver` と整合するよう、以下の要素から安定 ID を生成します。

- `kind`
- `fullPath`
- `folderRaw`
- `displayName`
- `sizeBytes`
- `modifiedEpochMs`

生成形式は `mid_<hash>` です。

## インストール

```bash
pip install -r requirements.txt
```

### requirements.txt

```txt
fastapi>=0.115,<1.0
uvicorn[standard]>=0.32,<1.0
pydantic>=2.9,<3.0
Pillow>=11.0,<12.0
pypdfium2>=4.30,<5.0
```

## サンプル設定

`server/.env.example`:

```env
MEDIA_SERVER_HOST=0.0.0.0
MEDIA_SERVER_PORT=8000
MEDIA_SERVER_AUTH_TOKEN=change-this-token
MEDIA_SERVER_MEDIA_ROOTS=\\\\PC\\share\\books;\\\\PC\\share\\images
MEDIA_SERVER_CORS_ORIGINS=http://127.0.0.1;http://localhost
MEDIA_SERVER_STARTUP_RESCAN=true
MEDIA_SERVER_LOG_LEVEL=INFO
```

### 主な設定項目

- `MEDIA_SERVER_HOST`
  - 待ち受けホスト
- `MEDIA_SERVER_PORT`
  - 待ち受けポート
- `MEDIA_SERVER_AUTH_TOKEN`
  - Bearer トークン。空なら認証なし運用
- `MEDIA_SERVER_MEDIA_ROOTS`
  - 再スキャン対象のルートフォルダ。`;` 区切り
- `MEDIA_SERVER_CORS_ORIGINS`
  - 許可 Origin。`;` 区切り
- `MEDIA_SERVER_STARTUP_RESCAN`
  - 起動時に初回スキャンするか
- `MEDIA_SERVER_DATA_DIR`
  - SQLite とサムネイルキャッシュの保存先

## 起動方法

PowerShell 例:

```powershell
$env:MEDIA_SERVER_HOST = '0.0.0.0'
$env:MEDIA_SERVER_PORT = '8000'
$env:MEDIA_SERVER_AUTH_TOKEN = 'change-this-token'
$env:MEDIA_SERVER_MEDIA_ROOTS = '\\\\PC\\share\\books;\\\\PC\\share\\images'
uvicorn server.main:app --host 0.0.0.0 --port 8000
```

ローカル確認 URL 例:

- `http://127.0.0.1:8000`
- `http://100.x.x.x:8000`
- `http://shared-pc.tailnet-name.ts.net:8000`

Flutter 側にはベース URL だけを入力してください。`/health` などのパスはアプリ側が自動で付与します。

## Tailscale 想定の運用メモ

- まずは Tailscale 内利用前提です。
- 一般公開は想定していません。
- 外出先から使う場合は、共有 Windows PC と閲覧端末の両方を同じ tailnet に参加させてください。
- 将来 HTTPS 化する場合は、リバースプロキシを前段に置ける構成です。

## API 契約

### 認証

- `Authorization: Bearer <token>` を送信します。
- `MEDIA_SERVER_AUTH_TOKEN` が空の場合のみ認証なし運用です。

### 1. GET /health

接続確認用です。

```json
{
  "ok": true,
  "service": "metadata-media-server",
  "version": "0.1.0"
}
```

### 2. GET /tags/master

タグマスター一覧を返します。

クエリ:

- `category`
- `contains`
- `limit`

### 3. GET /tags/item/{id}

`mediaId` に紐づくタグ一覧を返します。

### 4. POST /tags/item/{id}

タグを追加します。`tags` 配列に加えて、既存 Flutter 実装互換の `tag` 単体も受け付けます。

```json
{
  "tags": [
    { "name": "作家A", "category": "artist" },
    { "name": "シリーズB", "category": "series" }
  ]
}
```

### 5. DELETE /tags/item/{id}

タグ ID 配列で一括削除します。

```json
{
  "tagIds": ["artist:aaa", "series:bbb"]
}
```

補助互換 API として `DELETE /tags/item/{id}/{tagId}` も実装しています。

### 6. GET /search

タグ検索・複合検索・名前検索です。

対応クエリ:

- `q`
- `artist`
- `series`
- `character`
- `mediaType`
- `name`
- `partial`
- `folderRaw`
- `limit`
- `offset`

レスポンス例:

```json
{
  "items": [
    {
      "mediaId": "mid_xxx",
      "displayName": "sample.pdf",
      "folderRaw": "\\\\PC\\share\\books",
      "kind": "pdf",
      "fullPath": "\\\\PC\\share\\books\\sample.pdf"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

### 7. GET /untagged

未タグ一覧を返します。

クエリ:

- `folderRaw`
- `limit`
- `offset`

### 8. POST /rescan

フォルダ再スキャンです。`folderRaw` 指定ありなら単一フォルダ、未指定なら設定済みルート全部を走査します。

```json
{
  "folderRaw": "\\\\PC\\share\\images"
}
```

### 9. POST /rename

リネーム後の整合を反映します。

```json
{
  "oldMediaId": "media_old",
  "newMediaId": "media_new",
  "oldPath": "\\\\PC\\share\\a\\old.pdf",
  "newPath": "\\\\PC\\share\\a\\new.pdf"
}
```

現在の Flutter クライアント互換のため、`before` / `after` を含む拡張 payload も受け付けます。

### 10. POST /delete

削除後の整合を反映します。論理削除が基本です。

```json
{
  "mediaId": "media_001",
  "path": "\\\\PC\\share\\a\\x.png",
  "hardDelete": false
}
```

現在の Flutter クライアント互換のため、`items` 配列の一括削除 payload も受け付けます。

### 11. GET /media/{id}/meta

メディア本体取得前の情報を返します。

```json
{
  "mediaId": "media_001",
  "displayName": "book01.pdf",
  "kind": "pdf",
  "mimeType": "application/pdf",
  "sizeBytes": 12345678,
  "modifiedAt": "2026-03-27T10:00:00Z",
  "etag": "abc123",
  "supportsRange": true
}
```

### 12. GET /media/{id}/download

PDF / 画像本体を配信します。

- Range request 対応
- `Content-Type` 設定
- `ETag` 設定
- `Last-Modified` 設定
- deleted / missing は 404

### 13. GET /media/{id}/thumb

一覧用サムネイルを返します。

クエリ:

- `width`
- `height`
- `page`

実装:

- PDF は 1 開始の `page` を使用。未指定時は 1 ページ目
- 画像はリサイズして JPEG を返却
- `data/thumbs/` に簡易キャッシュ

### 14. GET /media/{id}/page/{pageNo}

PDF の特定ページを PNG にレンダリングして返します。

クエリ:

- `width`

注意:

- `pageNo` は 1 開始です
- PDF 以外に対しては JSON エラーを返します

### Flutter 連携用の補助 API

既存 UI を大きく崩さずフォルダ一覧と階層移動を維持するため、次の API も追加しています。

- `GET /folders`
- `GET /folders/children?folderRaw=...&limit=...&offset=...`

## curl 動作確認例

### ヘルスチェック

```bash
curl -H "Authorization: Bearer change-this-token" \
  http://127.0.0.1:8000/health
```

### タグマスター取得

```bash
curl -H "Authorization: Bearer change-this-token" \
  http://127.0.0.1:8000/tags/master
```

### フォルダ再スキャン

```bash
curl -X POST \
  -H "Authorization: Bearer change-this-token" \
  -H "Content-Type: application/json" \
  -d '{"folderRaw":"\\\\PC\\share\\books"}' \
  http://127.0.0.1:8000/rescan
```

### artist + series 複合検索

```bash
curl -G \
  -H "Authorization: Bearer change-this-token" \
  --data-urlencode "artist=作家A" \
  --data-urlencode "series=シリーズB" \
  http://127.0.0.1:8000/search
```

### PDF ダウンロード

```bash
curl -H "Authorization: Bearer change-this-token" \
  -o sample.pdf \
  http://127.0.0.1:8000/media/mid_xxx/download
```

### サムネイル取得

```bash
curl -H "Authorization: Bearer change-this-token" \
  -o thumb.jpg \
  "http://127.0.0.1:8000/media/mid_xxx/thumb?width=320&page=1"
```

## Flutter 側の組み込み内容

### 追加実装

- `RemoteMediaApiClient`
  - `/media/{id}/meta`
  - `/media/{id}/download`
  - `/media/{id}/thumb`
  - `/media/{id}/page/{pageNo}`
  - `/folders`
  - `/folders/children`
  - `/search`
- `RemoteMediaRepository`
  - 一時ファイルに PDF / 画像をキャッシュ
  - サムネイル簡易キャッシュ
  - `mediaId + etag` ベースのキャッシュキー
- `SwitchingMediaRepository`
  - ローカル / リモートを設定に応じて自動切替

### UI 側変更

- `gridGallery.dart`
  - リモートモード時はサーバーからフォルダ一覧取得
  - 一覧グリッドは `/media/{id}/thumb` を利用
  - リモート未対応機能は日本語スナックバーで通知
- `detailImage.dart`
  - リモート時も詳細画面から閲覧可能
  - PDF は一時ファイル経由で既存表示系を継続利用
  - フォルダ切替 UI はリモート時に無効化
- `main.dart` / `repositoryFactory.dart`
  - 起動時にメタデータ設定を読んでリポジトリを構築

## Flutter 側の設定入力例

メタデータ設定ダイアログの入力例:

- Mode: `Remote`
- API URL: `http://127.0.0.1:8000`
- API URL: `http://100.x.x.x:8000`
- API URL: `http://shared-pc.tailnet-name.ts.net:8000`
- Token: `change-this-token`

`API URL` はベース URL のみです。`/health` や `/search` は含めません。

## 想定動作シナリオ

以下の流れを前提にコードを揃えています。

1. 共有 Windows PC でサーバー起動
2. Tailscale 越しに `/health` 成功
3. Flutter アプリで remote mode を有効化
4. `http://shared-pc.tailnet-name.ts.net:8000` を入力
5. 接続確認成功
6. タグ一覧取得成功
7. 一覧グリッドで PDF 表紙サムネイルが見える
8. 画像サムネイルが見える
9. PDF を開ける
10. 画像を開ける
11. artist / series 検索成功
12. untagged 一覧成功
13. rename 後もタグが切れない
14. delete 後に検索結果から消える

## 最小実装で未対応のこと

- リモートモードでのアップロード / 取り込み
- リモートモードでの PDF 書き出し
- リモートモードでのライブラリ整理 UI
- サムネイルキャッシュの容量ベース厳密管理
- バックグラウンドジョブキュー化された再スキャン
- HTTPS 終端や証明書管理
- 複数ユーザー / 権限管理
- 大規模件数向けの検索 SQL 最適化

## 補足

- サーバー側は UTF-8、Windows パス、UNC パスを前提にしています。
- 削除は論理削除が基本です。`hardDelete=true` の場合のみ物理削除します。
- PDF ページ API の `pageNo` は README 記載どおり 1 開始です。
- Bearer トークンを空にすると開発用の認証なし運用ができます。
