import 'dart:convert';

import '../../core/cache/store/store.dart';
import '../../core/json.dart';

/// Fallback used where `dart:io` is unavailable (the web): keeps data in
/// memory only, with the same API as the file-backed store.
final class PersistentStore implements Store {
  PersistentStore._();

  /// Returns an in-memory store. Arguments are accepted for API parity.
  static Future<PersistentStore> open({
    String name = 'graphql_cache',
    Duration writeDelay = const Duration(milliseconds: 300),
    Future<String> Function()? directoryPath,
    Codec<String, String>? codec,
    void Function(Object error, StackTrace stackTrace)? onWriteError,
  }) async =>
      PersistentStore._();

  final InMemoryStore _memory = InMemoryStore();

  @override
  JsonMap? get(String id) => _memory.get(id);

  @override
  void put(String id, JsonMap? value) => _memory.put(id, value);

  @override
  void putAll(Map<String, JsonMap?> entries) => _memory.putAll(entries);

  @override
  void delete(String id) => _memory.delete(id);

  @override
  void clear() => _memory.clear();

  @override
  Iterable<String> get keys => _memory.keys;

  /// No-op: nothing is persisted.
  @override
  Future<void> flush() async {}

  @override
  Future<void> close() => _memory.close();
}
