from __future__ import annotations

from contextlib import closing
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import uuid

import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_raw

from server.core.errors import ApiError, bad_request, forbidden, not_found


def _revision(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class PdfEditService:
    def __init__(self, metadata, index, thumbnails, settings):
        self._metadata = metadata
        self._index = index
        self._thumbnails = thumbnails
        self._roots = [Path(path).resolve() for path in settings.media_roots]
        self._backups = settings.data_dir / '.pdf-edit-backups'

    def _path(self, media_id):
        media = self._metadata.get_media(media_id)
        path = Path(str(media['fullPath'])).resolve()
        if media['isDeleted'] or not path.is_file():
            raise not_found('PDFが見つかりません')
        if media['kind'] != 'pdf' or path.suffix.lower() != '.pdf':
            raise bad_request('PDFファイルのみ編集できます')
        if not any(path.is_relative_to(root) for root in self._roots):
            raise forbidden('管理対象フォルダー外のPDFは編集できません')
        return str(media['mediaId']), path

    def _backup_dir(self, media_id):
        return self._backups / hashlib.sha256(media_id.encode('utf-8')).hexdigest()

    def _open(self, data):
        try:
            pdf = pdfium.PdfDocument(data)
        except pdfium.PdfiumError as error:
            raise bad_request('PDFを開けません。暗号化・破損していないか確認してください') from error
        if pdfium_raw.FPDF_GetSecurityHandlerRevision(pdf) >= 0 or pdfium_raw.FPDF_GetSignatureCount(pdf) != 0:
            pdf.close()
            raise bad_request('暗号化・署名付きPDFは編集できません')
        return pdf

    def info(self, media_id):
        media_id, path = self._path(media_id)
        with self._thumbnails.pdf_mutation(str(path)):
            data = path.read_bytes()
            with closing(self._open(data)) as pdf:
                count = len(pdf)
        backups = []
        directory = self._backup_dir(media_id)
        if directory.is_dir():
            for manifest in directory.glob('*/backup.json'):
                try:
                    item = json.loads(manifest.read_text(encoding='utf-8'))
                    if item['mediaId'] == media_id and (manifest.parent / 'original.pdf').is_file():
                        backups.append({'id': manifest.parent.name, 'createdAt': item['createdAt'], 'pageCount': item['pageCount']})
                except (OSError, ValueError, KeyError):
                    continue
        backups.sort(key=lambda item: item['createdAt'], reverse=True)
        return {'mediaId': media_id, 'revision': _revision(data), 'pageCount': count, 'backups': backups}

    def edit(self, media_id, revision, pages):
        media_id, path = self._path(media_id)
        with self._thumbnails.pdf_mutation(str(path)):
            original = path.read_bytes()
            if _revision(original) != revision:
                raise ApiError(409, 'PDFが変更されています。編集画面を開き直してください')
            with closing(self._open(original)) as pdf:
                count = len(pdf)
                order = [item['page'] for item in pages]
                if not order or len(set(order)) != len(order) or any(type(page) is not int or not 1 <= page <= count for page in order):
                    raise bad_request('ページ番号が不正、重複、または全ページ削除になっています')
                if any(type(item['rotation']) is not int or item['rotation'] not in (0, 90, 180, 270) for item in pages):
                    raise bad_request('回転角度が不正です')
                if order == list(range(1, count + 1)) and not any(item['rotation'] for item in pages):
                    raise bad_request('変更がありません')
                for item in pages:
                    if item['rotation']:
                        with closing(pdf.get_page(item['page'] - 1)) as page:
                            page.set_rotation((page.get_rotation() + item['rotation']) % 360)
                retained = set(order)
                current = list(range(1, count + 1))
                for index in range(count - 1, -1, -1):
                    if index + 1 not in retained:
                        pdf.del_page(index)
                        current.pop(index)
                # Always move a later page to an earlier slot; document-level data is retained.
                for destination, page in enumerate(order):
                    index = current.index(page)
                    if index != destination:
                        indices = (ctypes.c_int * 1)(index)
                        if not pdfium_raw.FPDF_MovePages(pdf, indices, 1, destination):
                            raise bad_request('ページの並べ替えに失敗しました')
                        current.insert(destination, current.pop(index))
                temporary = self._temporary(path)
                try:
                    pdf.save(temporary)
                    with closing(pdfium.PdfDocument(temporary)) as checked:
                        if len(checked) != len(order):
                            raise bad_request('編集後のPDF検証に失敗しました')
                    return self._replace(media_id, path, original, count, temporary, order)
                finally:
                    temporary.unlink(missing_ok=True)

    def restore(self, media_id, revision, backup_id):
        media_id, path = self._path(media_id)
        if not isinstance(backup_id, str) or len(backup_id) != 32 or any(c not in '0123456789abcdef' for c in backup_id):
            raise bad_request('バックアップIDが不正です')
        directory = self._backup_dir(media_id) / backup_id
        if not (directory / 'backup.json').is_file():
            raise not_found('バックアップが見つかりません')
        manifest = json.loads((directory / 'backup.json').read_text(encoding='utf-8'))
        data = (directory / 'original.pdf').read_bytes()
        if manifest['mediaId'] != media_id or _revision(data) != manifest['revision']:
            raise bad_request('バックアップの検証に失敗しました')
        with self._thumbnails.pdf_mutation(str(path)):
            original = path.read_bytes()
            if _revision(original) != revision:
                raise ApiError(409, 'PDFが変更されています。編集画面を開き直してください')
            with closing(self._open(original)) as current, closing(self._open(data)) as restored:
                count, restored_count = len(current), len(restored)
            temporary = self._temporary(path)
            try:
                temporary.write_bytes(data)
                return self._replace(media_id, path, original, count, temporary, None, restored_count)
            finally:
                temporary.unlink(missing_ok=True)

    @staticmethod
    def _temporary(path):
        handle, name = tempfile.mkstemp(prefix='.pdf-edit-', suffix='.tmp', dir=path.parent)
        os.close(handle)
        return Path(name)

    def _replace(self, media_id, path, original, count, temporary, order, restored_count=None):
        if _revision(path.read_bytes()) != _revision(original):
            raise ApiError(409, '保存前にPDFが変更されました。編集画面を開き直してください')
        backup_id = uuid.uuid4().hex
        backup = self._backup_dir(media_id) / backup_id
        backup.mkdir(parents=True)
        with (backup / 'original.pdf').open('xb') as handle:
            handle.write(original)
            handle.flush()
            os.fsync(handle.fileno())
        manifest = {'mediaId': media_id, 'createdAt': datetime.now(timezone.utc).isoformat(), 'pageCount': count, 'revision': _revision(original)}
        with (backup / 'backup.json').open('w', encoding='utf-8') as handle:
            json.dump(manifest, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        with temporary.open('r+b') as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            if self._index.index_files([str(path)]) != 1:
                raise RuntimeError('PDF index refresh failed')
            self._update_progress(media_id, order, restored_count)
        except Exception:
            rollback = self._temporary(path)
            try:
                shutil.copyfile(backup / 'original.pdf', rollback)
                os.replace(rollback, path)
                self._index.index_files([str(path)])
            finally:
                rollback.unlink(missing_ok=True)
            raise
        return {'mediaId': media_id, 'pageCount': restored_count if order is None else len(order), 'revision': _revision(path.read_bytes()), 'backupId': backup_id}

    def _update_progress(self, media_id, order, restored_count):
        try:
            progress = self._metadata.get_reading_progress(media_id)
        except ApiError as error:
            if error.status_code == 404:
                return
            raise
        count = restored_count if order is None else len(order)
        old_page = progress['currentPage']
        if order is None:
            page = min(old_page, count)
        else:
            retained = min(order, key=lambda value: (abs(value - old_page), -value))
            page = order.index(retained) + 1
        self._metadata.upsert_reading_progress(
            media_id, current_page=page, total_pages=count,
            last_read_at=progress.get('lastReadAt'),
            updated_at=datetime.now(timezone.utc),
            is_bookmarked=progress.get('isBookmarked'),
        )
