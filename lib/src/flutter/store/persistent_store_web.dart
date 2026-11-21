import 'dart:convert';

import 'package:web/web.dart' as web;

import 'buffered_store.dart';

/// A [BufferedStore] saved to the browser's `localStorage`, so cached data
/// survives page reloads and is available offline.
///
/// All entities are loaded into memory by [open]; changes are written back
/// after `writeDelay` (batched). Browsers limit `localStorage` to about
/// 5 MB per site: a write that exceeds the quota is reported to
/// `onWriteError` and the in-memory cache keeps working.
///
/// **Security:** the data is plain JSON unless you pass a [Codec] that
/// encrypts it. Use a per-user name, and call `await client.resetStore()`
/// when the user signs out.
final class PersistentStore extends BufferedStore {
  PersistentStore._(
    this._key,
    super.data, {
    required super.writeDelay,
    super.codec,
    super.onWriteError,
  });

  /// Opens (or creates) the store named [name].
  ///
  /// [directoryPath] is ignored on the web. Corrupt data is discarded and
  /// the store starts empty.
  static Future<PersistentStore> open({
    String name = 'graphql_cache',
    Duration writeDelay = const Duration(milliseconds: 300),
    Future<String> Function()? directoryPath,
    Codec<String, String>? codec,
    WriteErrorHandler? onWriteError,
  }) async {
    BufferedStore.checkName(name);
    final key = 'graphql_client_flutter.$name';
    final storage = web.window.localStorage;
    final saved = storage.getItem(key);
    var data = saved == null ? null : BufferedStore.decode(saved, codec);
    if (saved != null && data == null) storage.removeItem(key);
    data ??= {};
    return PersistentStore._(
      key,
      data,
      writeDelay: writeDelay,
      codec: codec,
      onWriteError: onWriteError,
    );
  }

  final String _key;

  @override
  Future<void> persist(String contents) async {
    // Throws a QuotaExceededError DOMException when storage is full.
    web.window.localStorage.setItem(_key, contents);
  }
}
