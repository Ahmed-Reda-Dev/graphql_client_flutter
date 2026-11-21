import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/cache/store/store.dart';
import '../../core/json.dart';

/// A [Store] saved to a file, so cached data survives app restarts and is
/// available offline.
///
/// All entities are loaded into memory by [open]; changes are written back
/// after [writeDelay] (batched) using an atomic replace, so a crash during a
/// write never corrupts the file.
///
/// **Security:** the file is plain JSON unless you pass a [Codec] that
/// encrypts it (e.g. AES with a key from `flutter_secure_storage`). Use a
/// per-user [name], and call `await client.resetStore()` (or [clear] then
/// [flush]) when the user signs out.
///
/// ```dart
/// final client = GraphQLClient(
///   url,
///   cache: GraphQLCache(store: await PersistentStore.open()),
/// );
/// ```
final class PersistentStore implements Store {
  PersistentStore._(
    this._file,
    this._data,
    this.writeDelay,
    this._codec,
    this._onWriteError,
  );

  /// Opens (or creates) the store named [name].
  ///
  /// Files live in the app support directory unless [directoryPath] returns
  /// another one. A corrupt file is discarded and the store starts empty.
  static Future<PersistentStore> open({
    String name = 'graphql_cache',
    Duration writeDelay = const Duration(milliseconds: 300),
    Future<String> Function()? directoryPath,
    Codec<String, String>? codec,
    void Function(Object error, StackTrace stackTrace)? onWriteError,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Use only letters, digits, "_" and "-"',
      );
    }
    final directory = directoryPath != null
        ? await directoryPath()
        : (await getApplicationSupportDirectory()).path;
    await Directory(directory).create(recursive: true);
    final file = File('$directory/$name.json');
    // A crash between writing the temp file and renaming it leaves it behind.
    final leftover = File('${file.path}.tmp');
    if (await leftover.exists()) await leftover.delete();
    return PersistentStore._(
      file,
      await _load(file, codec),
      writeDelay,
      codec,
      onWriteError,
    );
  }

  /// How long changes are batched before being written.
  final Duration writeDelay;

  final File _file;
  final Map<String, JsonMap> _data;
  final Codec<String, String>? _codec;
  final void Function(Object error, StackTrace stackTrace)? _onWriteError;
  Timer? _flushTimer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  @override
  JsonMap? get(String id) => _data[id];

  @override
  void put(String id, JsonMap? value) {
    if (value == null) {
      _data.remove(id);
    } else {
      _data[id] = value;
    }
    _scheduleFlush();
  }

  @override
  void putAll(Map<String, JsonMap?> entries) {
    entries.forEach((id, value) {
      if (value == null) {
        _data.remove(id);
      } else {
        _data[id] = value;
      }
    });
    _scheduleFlush();
  }

  @override
  void delete(String id) {
    if (_data.remove(id) != null) _scheduleFlush();
  }

  /// Removes everything and starts writing the empty store immediately
  /// (await [flush] to be sure it reached the disk).
  @override
  void clear() {
    _data.clear();
    unawaited(flush().catchError(_report));
  }

  @override
  Iterable<String> get keys => _data.keys;

  /// Writes pending changes now.
  ///
  /// The returned future fails if this write fails; later writes still run,
  /// so one I/O error (e.g. a full disk) never stops persistence for good.
  @override
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final json = jsonEncode(_data);
    final snapshot = _codec?.encode(json) ?? json;
    // Chain writes so they land in order, isolating each one's failure.
    final write = _writing.then((_) => _write(snapshot));
    _writing = write.catchError((Object _) {});
    return write;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_flushTimer != null) await flush().catchError(_report);
    await _writing;
  }

  void _scheduleFlush() {
    if (_closed) return;
    _flushTimer?.cancel();
    _flushTimer =
        Timer(writeDelay, () => unawaited(flush().catchError(_report)));
  }

  /// Background write failures go to [_onWriteError], or to the current
  /// zone so they are never silently lost.
  void _report(Object error, StackTrace stackTrace) {
    final handler = _onWriteError;
    if (handler != null) {
      handler(error, stackTrace);
    } else {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  Future<void> _write(String contents) async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(_file.path);
  }

  static Future<Map<String, JsonMap>> _load(
    File file,
    Codec<String, String>? codec,
  ) async {
    if (!await file.exists()) return {};
    try {
      final contents = await file.readAsString();
      final decoded = jsonDecode(codec?.decode(contents) ?? contents);
      if (decoded is! JsonMap) throw const FormatException('Not an object');
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (value is JsonMap) key: value,
      };
    } on Exception {
      // Corrupt, or written with a different codec/key: start empty.
      await file.delete();
      return {};
    }
  }
}
