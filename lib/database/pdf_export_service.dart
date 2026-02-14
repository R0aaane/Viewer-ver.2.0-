import 'dart:isolate';
import 'dart:typed_data';

import 'package:docman/docman.dart';
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

class PdfExportService {
  /// ✅ 保存先をユーザーに選ばせて（SAF）PDFを書き出す
  /// 戻り値：作成された DocumentFile（uriなどが取れる）
  static Future<DocumentFile?> exportFolderToPdfPickLocation(
    MediaRepository repo,
    List<MediaItem> items,
    String fileName, {
    double longSidePt = 842.0,
    void Function(int done, int total)? onProgress,
  }) async {
    // 1) 保存先フォルダを選択（SAF）
    final dir = await DocMan.pick.directory();
    if (dir == null) return null;

    // 2) PDFバイトを生成（Isolate）
    final pdfBytes = await _buildPdfBytesIsolate(
      repo,
      items,
      longSidePt: longSidePt,
      onProgress: onProgress,
    );

    // 3) 既に同名があれば削除して作り直し（docmanは既存上書きが弱い）
    final safeName = _sanitizePdfName(fileName);
    final existing = await dir.find('$safeName.pdf');
    if (existing != null) {
      await existing.delete();
    }

    // 4) 選択フォルダへPDF作成
    final created = await dir.createFile(
      name: '$safeName.pdf',
      bytes: pdfBytes,
    );

    return created;
  }

  static String _sanitizePdfName(String name) {
    final n = name.trim().isEmpty ? 'export' : name.trim();
    // Windows/Android的に危ない文字をざっくり除去
    return n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static Future<Uint8List> _buildPdfBytesIsolate(
    MediaRepository repo,
    List<MediaItem> items, {
    required double longSidePt,
    void Function(int done, int total)? onProgress,
  }) async {
    final targets =
        items.where((e) => e.kind == MediaKind.image).toList(growable: false);
    final total = targets.length;

    final worker = await _PdfWorker.spawn(longSidePt: longSidePt);

    try {
      for (int i = 0; i < total; i++) {
        final bytes = await repo.readBytes(targets[i]);
        await worker.addImage(TransferableTypedData.fromList([bytes]));
        onProgress?.call(i + 1, total);

        if (i % 2 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      return await worker.save();
    } finally {
      worker.dispose();
    }
  }
}

/// --- isolate worker ---
class _PdfWorker {
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  _PdfWorker._(this._sendPort, this._receivePort);

  static Future<_PdfWorker> spawn({required double longSidePt}) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(
      _pdfIsolateEntry,
      _IsolateInit(receivePort.sendPort, longSidePt),
      debugName: 'pdf_export_worker',
    );
    final sendPort = await receivePort.first as SendPort;
    return _PdfWorker._(sendPort, receivePort);
  }

  Future<void> addImage(TransferableTypedData data) async {
    final rp = ReceivePort();
    _sendPort.send({'cmd': 'add', 'reply': rp.sendPort, 'data': data});
    await rp.first;
    rp.close();
  }

  Future<Uint8List> save() async {
    final rp = ReceivePort();
    _sendPort.send({'cmd': 'save', 'reply': rp.sendPort});
    final msg = await rp.first;
    rp.close();
    final ttd = msg as TransferableTypedData;
    return ttd.materialize().asUint8List();
  }

  void dispose() {
    _sendPort.send({'cmd': 'close'});
    _receivePort.close();
  }
}

class _IsolateInit {
  final SendPort mainSendPort;
  final double longSidePt;
  _IsolateInit(this.mainSendPort, this.longSidePt);
}

void _pdfIsolateEntry(_IsolateInit init) {
  final port = ReceivePort();
  init.mainSendPort.send(port.sendPort);

  final pdf = pw.Document(compress: true);

  port.listen((msg) async {
    if (msg is! Map) return;
    final cmd = msg['cmd'];

    if (cmd == 'add') {
      final SendPort reply = msg['reply'] as SendPort;
      final TransferableTypedData ttd = msg['data'] as TransferableTypedData;
      final bytes = ttd.materialize().asUint8List();

      final decoded = im.decodeImage(bytes);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        reply.send(true);
        return;
      }

      final w = decoded.width.toDouble();
      final h = decoded.height.toDouble();

      // 画像比率に合わせた可変ページ（トリミングなし）
      final bool landscape = w >= h;
      final double pageW =
          landscape ? init.longSidePt : init.longSidePt * (w / h);
      final double pageH =
          landscape ? init.longSidePt * (h / w) : init.longSidePt;

      final img = pw.MemoryImage(bytes);

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageW, pageH),
          margin: pw.EdgeInsets.zero, // ✅ 余白ゼロ
          build: (_) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Image(
              img,
              width: pageW,
              height: pageH,
              fit: pw.BoxFit.contain, // ✅ トリミングなし
            ),
          ),
        ),
      );

      reply.send(true);
      return;
    }

    if (cmd == 'save') {
      final SendPort reply = msg['reply'] as SendPort;
      final out = await pdf.save();
      reply.send(TransferableTypedData.fromList([out]));
      return;
    }

    if (cmd == 'close') {
      port.close();
      return;
    }
  });
}
