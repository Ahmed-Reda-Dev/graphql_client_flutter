import 'dart:async';
import 'dart:convert';

import '../../core/cache/store/store.dart';
import '../../core/json.dart';

/// Reports a failed background write.
typedef WriteErrorHandler = void Function(Object error, StackTrace stackTrace);

/// A [Store] that keeps every entity in memory and saves the whole map in
/// the background, batching changes made within [writeDelay].
///
/// Subclasses only implement [persist]. Writes are chained so they land in
/// order, and one failed write never stops later ones.
abstract class BufferedStore implements Store {
  /// Creates a store over [data] (as loaded by the subclass).
  BufferedStore(
    this._data, {
    required this.writeDelay,
    Codec<String, String>? codec,
    WriteErrorHandler? onWriteError,
  })  : _codec = codec,
        _onWriteError = onWriteError;

  /// How long changes are batched before being written.
  final Duration writeDelay;

  final Map<String, JsonMap> _data;
  final Codec<String, String>? _codec;
  final WriteErrorHandler? _onWriteError;
  Timer? _flushTimer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Saves [contents] (the encoded store) to the backing medium.
  Future<void> persist(String contents);

  /// Decodes saved [contents], or returns null if it is corrupt or was
  /// written with a different [codec] (the caller then starts empty).
  static Map<String, JsonMap>? decode(
    String contents,
    Codec<String, String>? codec,
  ) {
    try {
      final decoded = jsonDecode(codec?.decode(contents) ?? contents);
      if (decoded is! JsonMap) return null;
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (value is JsonMap) key: value,
      };
    } on Exception {
      return null;
    }
  }

  /// Whether [name] is safe to use as a file name or storage key.
  static void checkName(String name) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Use only letters, digits, "_" and "-"',
      );
    }
  }

  @override
  JsonMap? get(String id) => _data[id];

  @override
  void put(String id, JsonMap? value) {
    _apply(id, value);
    _scheduleFlush();
  }

  @override
  void putAll(Map<String, JsonMap?> entries) {
    entries.forEach(_apply);
    _scheduleFlush();
  }

  @override
  void delete(String id) {
    if (_data.remove(id) != null) _scheduleFlush();
  }

  /// Removes everything and starts writing the empty store immediately
  /// (await [flush] to be sure it was saved).
  @override
  void clear() {
    _data.clear();
    unawaited(flush().catchError(_report));
  }

  @override
  Iterable<String> get keys => _data.keys;

  /// Writes pending changes now.
  ///
  /// The returned future fails if this write fails; later writes still run.
  @override
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final json = jsonEncode(_data);
    final snapshot = _codec?.encode(json) ?? json;
    final write = _writing.then((_) => persist(snapshot));
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

  void _apply(String id, JsonMap? value) {
    if (value == null) {
      _data.remove(id);
    } else {
      _data[id] = value;
    }
  }

  void _scheduleFlush() {
    if (_closed) return;
    _flushTimer?.cancel();
    _flushTimer =
        Timer(writeDelay, () => unawaited(flush().catchError(_report)));
  }

  /// Background write failures go to the handler, or to the current zone,
  /// so they are never silently lost.
  void _report(Object error, StackTrace stackTrace) {
    final handler = _onWriteError;
    if (handler != null) {
      handler(error, stackTrace);
    } else {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}
