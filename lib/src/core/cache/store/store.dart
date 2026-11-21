import '../../json.dart';

/// Key-value storage for normalized cache entities.
///
/// Keys are entity ids such as `User:42` or `Query`; values are normalized
/// JSON objects. Reads are synchronous because normalization walks the
/// store field by field; persistent implementations load their data into
/// memory up front and write back in the background.
abstract interface class Store {
  /// The entity stored under [id], or null.
  JsonMap? get(String id);

  /// Stores [value] under [id]. A null value deletes the entry.
  void put(String id, JsonMap? value);

  /// Stores several entities at once.
  void putAll(Map<String, JsonMap?> entries);

  /// Removes the entity stored under [id].
  void delete(String id);

  /// Removes everything.
  void clear();

  /// All stored ids.
  Iterable<String> get keys;

  /// Completes when every change so far has been persisted.
  Future<void> flush();

  /// Releases resources and flushes pending writes.
  Future<void> close();
}

/// A [Store] that keeps everything in memory. The default.
final class InMemoryStore implements Store {
  /// Creates an empty store, or one seeded with [initial] entries.
  InMemoryStore([Map<String, JsonMap>? initial]) : _data = {...?initial};

  final Map<String, JsonMap> _data;

  @override
  JsonMap? get(String id) => _data[id];

  @override
  void put(String id, JsonMap? value) {
    if (value == null) {
      _data.remove(id);
    } else {
      _data[id] = value;
    }
  }

  @override
  void putAll(Map<String, JsonMap?> entries) => entries.forEach(put);

  @override
  void delete(String id) => _data.remove(id);

  @override
  void clear() => _data.clear();

  @override
  Iterable<String> get keys => _data.keys;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
