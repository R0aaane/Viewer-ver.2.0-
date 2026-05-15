import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

class EpubTextChapter {
  final String title;
  final String body;

  const EpubTextChapter({required this.title, required this.body});
}

class EpubTextDocument {
  final String title;
  final List<EpubTextChapter> chapters;

  const EpubTextDocument({required this.title, required this.chapters});
}

class EpubTextExtractor {
  static EpubTextDocument parse(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final container = _readText(archive, 'META-INF/container.xml');
    final rootfile = _firstAttr(container, 'rootfile', 'full-path');
    if (rootfile == null || rootfile.isEmpty) {
      throw const FormatException('EPUB rootfile not found');
    }

    final opf = _readText(archive, rootfile);
    final opfDoc = XmlDocument.parse(opf);
    final manifest = <String, String>{};
    for (final item in opfDoc.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] = p.url.normalize(
          p.url.join(p.url.dirname(rootfile), href),
        );
      }
    }

    final title = opfDoc.findAllElements('title').firstOrNull?.innerText.trim();
    final chapters = <EpubTextChapter>[];
    for (final itemref in opfDoc.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      final href = idref == null ? null : manifest[idref];
      if (href == null) continue;
      final html = _tryReadText(archive, href);
      if (html == null) continue;
      final chapter = _htmlToChapter(html, fallbackTitle: p.url.basename(href));
      if (chapter.body.isNotEmpty) {
        chapters.add(chapter);
      }
    }

    return EpubTextDocument(
      title: (title == null || title.isEmpty) ? 'EPUB' : title,
      chapters: chapters,
    );
  }

  static EpubTextChapter _htmlToChapter(
    String html, {
    required String fallbackTitle,
  }) {
    final doc = XmlDocument.parse(_sanitizeHtml(html));
    final title = doc.findAllElements('title').firstOrNull?.innerText.trim();
    final buffer = StringBuffer();
    for (final node in doc.descendants.whereType<XmlText>()) {
      final text = node.value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      buffer.writeln(text);
      buffer.writeln();
    }
    return EpubTextChapter(
      title: (title == null || title.isEmpty) ? fallbackTitle : title,
      body: buffer.toString().trim(),
    );
  }

  static String _sanitizeHtml(String html) {
    return html
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '')
        .replaceAll('&nbsp;', ' ');
  }

  static String? _firstAttr(String xml, String element, String attr) {
    final doc = XmlDocument.parse(xml);
    return doc.findAllElements(element).firstOrNull?.getAttribute(attr);
  }

  static String _readText(Archive archive, String name) {
    final text = _tryReadText(archive, name);
    if (text == null) {
      throw FormatException('EPUB file not found: $name');
    }
    return text;
  }

  static String? _tryReadText(Archive archive, String name) {
    final normalized = name.replaceAll('\\', '/');
    final file = archive.files
        .where((entry) => entry.name.replaceAll('\\', '/') == normalized)
        .firstOrNull;
    if (file == null || !file.isFile) return null;
    return utf8.decode(file.content as List<int>, allowMalformed: true);
  }
}
