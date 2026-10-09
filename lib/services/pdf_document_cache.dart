import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pdfx/pdfx.dart';

/// Serializes access to each PDF and keeps queued/active documents out of LRU
/// eviction. Opening, rendering and closing must share the same lease.
class PdfDocumentCache {
  PdfDocumentCache({this.maxEntries = 6}) : assert(maxEntries > 0);

  final int maxEntries;
  final _documents = <String, PdfDocument>{};
  final _tails = <String, Future<void>>{};
  final _pending = <String, int>{};
  Future<void>? _mutationBarrier;
  Future<void>? _disposal;

  Set<String> get pinnedPaths => {..._documents.keys, ..._pending.keys};

  Future<T> use<T>(
    String key,
    Future<PdfDocument> Function() open,
    Future<T> Function(PdfDocument document) action,
  ) => run(key, () async {
    final document = _documents.remove(key) ?? await open();
    _documents[key] = document;
    return action(document);
  });

  /// The callback must not acquire another lease for the same key.
  Future<T> run<T>(String key, Future<T> Function() action) async {
    if (_disposal != null) {
      throw StateError('PDF document cache is disposed');
    }
    final mutation = _mutationBarrier;
    final previous = _tails[key];
    final gate = Completer<void>();
    _tails[key] = gate.future;
    _pending[key] = (_pending[key] ?? 0) + 1;
    try {
      if (mutation != null) await mutation;
      if (previous != null) await previous;
      return await action();
    } finally {
      final remaining = _pending[key]! - 1;
      if (remaining == 0) {
        _pending.remove(key);
      } else {
        _pending[key] = remaining;
      }
      await _trim();
      if (identical(_tails[key], gate.future)) _tails.remove(key);
      gate.complete();
    }
  }

  /// Drains accepted work, closes matching documents, and prevents reopening
  /// during a filesystem change. The callback must not call this cache.
  /// Mutations are rare; a global barrier also covers not-yet-open descendants
  /// of renamed/deleted folders without keeping an unbounded path lock table.
  Future<T> mutateWhere<T>(
    bool Function(String) matches,
    Future<T> Function() action,
  ) async {
    if (_disposal != null) {
      throw StateError('PDF document cache is disposed');
    }
    final previous = _mutationBarrier;
    final accepted = _tails.values.toList(growable: false);
    final gate = Completer<void>();
    _mutationBarrier = gate.future;
    try {
      if (previous != null) await previous;
      await Future.wait(accepted);
      final keys = _documents.keys.where(matches).toList(growable: false);
      for (final key in keys) {
        await _documents[key]!.close();
        _documents.remove(key);
      }
      return await action();
    } finally {
      if (identical(_mutationBarrier, gate.future)) _mutationBarrier = null;
      gate.complete();
    }
  }

  Future<void> evictWhere(bool Function(String) matches) async {
    final keys = pinnedPaths.where(matches).toList(growable: false);
    for (final key in keys) {
      await run(key, () async {
        final document = _documents.remove(key);
        if (document != null) await document.close();
      });
    }
  }

  Future<void> _trim() async {
    while (_documents.length > maxEntries) {
      final idle = _documents.keys.where((key) => !_pending.containsKey(key));
      if (idle.isEmpty) return;
      await _closeQuietly(_documents.remove(idle.first)!);
    }
  }

  Future<void> _closeQuietly(PdfDocument document) async {
    try {
      await document.close();
    } catch (error) {
      debugPrint('PDF document close failed: $error');
    }
  }

  Future<void> dispose() => _disposal ??= _drainAndClose();

  Future<void> _drainAndClose() async {
    await Future.wait([
      ?_mutationBarrier,
      ..._tails.values,
    ]);
    final documents = _documents.values.toList(growable: false);
    _documents.clear();
    for (final document in documents) {
      await _closeQuietly(document);
    }
  }
}
