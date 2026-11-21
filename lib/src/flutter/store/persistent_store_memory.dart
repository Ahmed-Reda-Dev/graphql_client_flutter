import 'dart:convert';

import '../../core/json.dart';
import 'buffered_store.dart';

/// Fallback for platforms with neither `dart:io` nor a browser: keeps data
/// in memory only, with the same API as the persistent stores.
final class PersistentStore extends BufferedStore {
  PersistentStore._() : super(<String, JsonMap>{}, writeDelay: Duration.zero);

  /// Returns an in-memory store. Arguments are accepted for API parity.
  static Future<PersistentStore> open({
    String name = 'graphql_cache',
    Duration writeDelay = const Duration(milliseconds: 300),
    Future<String> Function()? directoryPath,
    Codec<String, String>? codec,
    WriteErrorHandler? onWriteError,
  }) async {
    BufferedStore.checkName(name);
    return PersistentStore._();
  }

  /// No-op: nothing is persisted.
  @override
  Future<void> persist(String contents) async {}
}
