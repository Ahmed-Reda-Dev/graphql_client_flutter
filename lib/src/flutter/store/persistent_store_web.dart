import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'buffered_store.dart';

/// A [BufferedStore] saved in the browser's IndexedDB, so cached data
/// survives page reloads and is available offline.
///
/// IndexedDB holds far more than `localStorage` (typically hundreds of MB,
/// depending on the browser and free disk space). Where it is unavailable
/// (some private modes, sandboxed iframes), the store falls back to
/// `localStorage`, limited to about 5 MB. Data saved by earlier versions in
/// `localStorage` is moved to IndexedDB on first open.
///
/// All entities are loaded into memory by [open]; changes are written back
/// after `writeDelay` (batched). A write that fails (e.g. over quota) is
/// reported to `onWriteError` and the in-memory cache keeps working.
///
/// **Security:** the data is plain JSON unless you pass a [Codec] that
/// encrypts it. Use a per-user name, and call `await client.resetStore()`
/// when the user signs out.
final class PersistentStore extends BufferedStore {
  PersistentStore._(
    this._storage,
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
    final storage = await _IndexedDbStorage.open(key) ?? _LocalStorage(key);

    var saved = await storage.read();
    if (saved == null && storage is _IndexedDbStorage) {
      saved = await _moveFromLocalStorage(key, storage);
    }
    var data = saved == null ? null : BufferedStore.decode(saved, codec);
    if (saved != null && data == null) await storage.remove();
    data ??= {};

    return PersistentStore._(
      storage,
      data,
      writeDelay: writeDelay,
      codec: codec,
      onWriteError: onWriteError,
    );
  }

  /// Moves a snapshot saved by versions before 2.4 into IndexedDB.
  static Future<String?> _moveFromLocalStorage(
    String key,
    _IndexedDbStorage storage,
  ) async {
    final legacy = web.window.localStorage.getItem(key);
    if (legacy == null) return null;
    await storage.write(legacy);
    web.window.localStorage.removeItem(key);
    return legacy;
  }

  final _WebStorage _storage;

  @override
  Future<void> persist(String contents) => _storage.write(contents);

  @override
  Future<void> close() async {
    await super.close();
    _storage.close();
  }
}

/// Where the store's snapshot lives in the browser.
abstract interface class _WebStorage {
  Future<String?> read();
  Future<void> write(String contents);
  Future<void> remove();
  void close();
}

/// Keeps the snapshot as one value in an IndexedDB object store.
final class _IndexedDbStorage implements _WebStorage {
  _IndexedDbStorage._(this._db, this._key);

  static const _database = 'graphql_client_flutter';
  static const _objectStore = 'stores';

  final web.IDBDatabase _db;
  final String _key;

  /// Opens the database, or returns null when IndexedDB is unavailable.
  static Future<_IndexedDbStorage?> open(String key) async {
    final web.IDBOpenDBRequest request;
    try {
      request = web.window.indexedDB.open(_database, 1);
    } on Object {
      // Browsers throw (a DOMException or a TypeError) when IndexedDB is
      // blocked; JavaScript errors are not Dart Exceptions.
      return null;
    }
    request.onupgradeneeded = ((web.Event _) {
      (request.result! as web.IDBDatabase).createObjectStore(_objectStore);
    }).toJS;
    try {
      final db = await _complete(request) as web.IDBDatabase;
      return _IndexedDbStorage._(db, key);
    } on StateError {
      return null;
    }
  }

  @override
  Future<String?> read() async {
    final value = await _complete(_store('readonly').get(_key.toJS));
    return value.isA<JSString>() ? (value! as JSString).toDart : null;
  }

  @override
  Future<void> write(String contents) =>
      _commit((store) => store.put(contents.toJS, _key.toJS));

  @override
  Future<void> remove() => _commit((store) => store.delete(_key.toJS));

  @override
  void close() => _db.close();

  web.IDBObjectStore _store(String mode) =>
      _db.transaction(_objectStore.toJS, mode).objectStore(_objectStore);

  /// Runs [change] in a read-write transaction and completes once it is
  /// committed (a failed or aborted transaction, e.g. over quota, fails).
  Future<void> _commit(void Function(web.IDBObjectStore store) change) {
    final transaction = _db.transaction(_objectStore.toJS, 'readwrite');
    final done = Completer<void>();
    void fail(web.Event _) {
      if (done.isCompleted) return;
      done.completeError(StateError(
        'IndexedDB write failed: '
        '${transaction.error?.message ?? 'transaction aborted'}',
      ));
    }

    transaction
      ..oncomplete = ((web.Event _) => done.complete()).toJS
      ..onerror = fail.toJS
      ..onabort = fail.toJS;
    change(transaction.objectStore(_objectStore));
    return done.future;
  }

  /// The result of [request], or a [StateError] if it fails.
  static Future<JSAny?> _complete(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request
      ..onsuccess = ((web.Event _) => done.complete(request.result)).toJS
      ..onerror = ((web.Event event) {
        event.preventDefault(); // Handled here; do not log it as uncaught.
        done.completeError(StateError(
          'IndexedDB request failed: ${request.error?.message}',
        ));
      }).toJS;
    return done.future;
  }
}

/// The fallback: `localStorage`, limited to about 5 MB per site.
final class _LocalStorage implements _WebStorage {
  _LocalStorage(this._key);

  final String _key;

  @override
  Future<String?> read() async => web.window.localStorage.getItem(_key);

  /// Throws a QuotaExceededError DOMException when storage is full.
  @override
  Future<void> write(String contents) async =>
      web.window.localStorage.setItem(_key, contents);

  @override
  Future<void> remove() async => web.window.localStorage.removeItem(_key);

  @override
  void close() {}
}
