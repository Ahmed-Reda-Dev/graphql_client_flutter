import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as gql;
import 'package:normalize/normalize.dart';
import 'package:normalize/utils.dart' as normalize_utils;
import 'package:source_span/source_span.dart';

import '../json.dart';
import '../request/graphql_document.dart';
import '../request/graphql_request.dart';
import '../response/graphql_exception.dart';
import 'entity_lru.dart';
import 'store/store.dart';

/// A normalized cache of GraphQL results.
///
/// Objects with a `__typename` and an `id` (or `_id`, or the key fields of a
/// [TypePolicy]) are stored once under `Typename:id`, so updating an object
/// through any query or mutation updates every result that contains it.
/// Watched queries are notified through [changes].
final class GraphQLCache {
  /// Creates a cache.
  ///
  /// [typePolicies] customise ids (`keyFields`) and field merging;
  /// [dataIdFromObject] computes ids for every object; [possibleTypes] maps
  /// interfaces and unions to their concrete types for fragment matching.
  ///
  /// [maxEntities] caps how many objects are kept: past it, the least
  /// recently read or written ones are evicted, and results that showed
  /// them are fetched again when next needed. Set it well above what one
  /// screen shows. Null (the default) keeps everything.
  ///
  /// [clock] supplies the current time for freshness checks (`maxAge`);
  /// override it in tests.
  GraphQLCache({
    Store? store,
    this.typePolicies = const {},
    this.dataIdFromObject,
    this.possibleTypes = const {},
    int? maxEntities,
    DateTime Function()? clock,
  })  : store = store ?? InMemoryStore(),
        _clock = clock ?? DateTime.now {
    if (maxEntities != null) {
      _lru = EntityLru(
        maxEntities,
        existing: this.store.keys,
        typePolicies: typePolicies,
      );
    }
  }

  /// Where normalized entities are kept.
  final Store store;

  /// Per-type id and field configuration.
  final Map<String, TypePolicy> typePolicies;

  /// Computes an object's cache id. Return null to keep it inline.
  final normalize_utils.DataIdResolver? dataIdFromObject;

  /// Concrete types of each interface and union.
  final Map<String, Set<String>> possibleTypes;

  final _changes = StreamController<void>.broadcast(sync: false);
  final DateTime Function() _clock;
  EntityLru? _lru;

  /// Store entry holding when each query result was last written, keyed by
  /// a hash of the request. Ids starting with `$` are never entities.
  static const _writeTimesId = r'$writeTimes';
  static const _maxWriteTimes = 500;

  /// Optimistic layers, oldest first. Each maps entity ids to the fields
  /// that layer changed (or null for an entity the layer removed).
  final _optimisticLayers = <Object, Map<String, JsonMap?>>{};
  Map<String, JsonMap?>? _writingLayer;
  bool _notifyScheduled = false;
  int _generation = 0;

  /// Emits after every change to the cache contents.
  Stream<void> get changes => _changes.stream;

  /// Increases every time the cache is [clear]ed. Requests started before a
  /// clear compare it to avoid writing stale results (e.g. the previous
  /// user's data after sign-out).
  int get generation => _generation;

  // Operations ---------------------------------------------------------------

  /// Reads the complete result of [request] from the cache, or null when any
  /// selected field is missing.
  ///
  /// With [optimistic] (the default), unconfirmed optimistic data is
  /// included.
  JsonMap? readQuery(GraphQLRequest request, {bool optimistic = true}) {
    final data = denormalizeOperation(
      read: (id) => _read(id, optimistic: optimistic),
      document: request.document.ast,
      operationName: request.operationName,
      variables: request.variables,
      typePolicies: typePolicies,
      dataIdFromObject: dataIdFromObject,
      possibleTypes: possibleTypes,
    );
    // Servers answer the root __typename with "Query", but data written
    // without it (mocks, writeQuery calls) reads back as null. Drop the null
    // so cached data matches what was written.
    if (data != null &&
        data.containsKey('__typename') &&
        data['__typename'] == null) {
      return {...data}..remove('__typename');
    }
    return data;
  }

  /// Writes the result of [request] into the cache.
  void writeQuery(GraphQLRequest request, JsonMap data) {
    if (_writingLayer == null && request.type == GraphQLOperationType.query) {
      _recordWriteTime(request);
    }
    normalizeOperation(
      read: (id) => _read(id, optimistic: _writingLayer != null),
      write: _write,
      document: request.document.ast,
      operationName: request.operationName,
      variables: request.variables,
      data: data,
      typePolicies: typePolicies,
      dataIdFromObject: dataIdFromObject,
      possibleTypes: possibleTypes,
    );
    _evictOverflow();
    _scheduleNotify();
  }

  /// Reads [document] (a query) with [variables] from the cache.
  ///
  /// A convenience over [readQuery] for `update` callbacks.
  JsonMap? read(
    String document, {
    JsonMap variables = const {},
    String? operationName,
    bool optimistic = true,
  }) =>
      readQuery(
        _request(document, variables, operationName),
        optimistic: optimistic,
      );

  /// Writes [data] as the result of [document] (a query) with [variables].
  void write(
    String document,
    JsonMap data, {
    JsonMap variables = const {},
    String? operationName,
  }) =>
      writeQuery(_request(document, variables, operationName), data);

  // Fragments ----------------------------------------------------------------

  /// Reads one object through a fragment.
  ///
  /// [idFields] identify the object, e.g. `{'__typename': 'User', 'id': '1'}`.
  JsonMap? readFragment(
    String fragment, {
    required JsonMap idFields,
    String? fragmentName,
    JsonMap variables = const {},
    bool optimistic = true,
  }) =>
      denormalizeFragment(
        read: (id) => _read(id, optimistic: optimistic),
        document: _parseFragment(fragment),
        idFields: idFields,
        fragmentName: fragmentName,
        variables: variables,
        typePolicies: typePolicies,
        dataIdFromObject: dataIdFromObject,
        addTypename: true,
        possibleTypes: possibleTypes,
      );

  /// Writes one object through a fragment.
  void writeFragment(
    String fragment, {
    required JsonMap idFields,
    required JsonMap data,
    String? fragmentName,
    JsonMap variables = const {},
  }) {
    normalizeFragment(
      read: (id) => _read(id, optimistic: _writingLayer != null),
      write: _write,
      document: _parseFragment(fragment),
      idFields: idFields,
      data: data,
      fragmentName: fragmentName,
      variables: variables,
      typePolicies: typePolicies,
      dataIdFromObject: dataIdFromObject,
      possibleTypes: possibleTypes,
    );
    _evictOverflow();
    _scheduleNotify();
  }

  // Entities -----------------------------------------------------------------

  /// The cache id of [object] (e.g. `User:1`), or null if it has none.
  String? identify(JsonMap object) => normalize_utils.identify(
        object,
        typePolicies: typePolicies,
        dataIdFromObject: dataIdFromObject,
      );

  /// Removes the entity [id]. Results that referenced it become incomplete
  /// and will be refetched by watching queries.
  void evict(String id) {
    if (_writingLayer != null) {
      _writingLayer![id] = null;
    } else {
      store.delete(id);
      _lru?.remove(id);
    }
    _scheduleNotify();
  }

  /// Removes entities that no root query, mutation or subscription can reach.
  void gc() {
    final reachable = normalize_utils.reachableIds(
      store.get,
      typePolicies,
    );
    final unreachable = store.keys
        .where((id) => !id.startsWith(r'$') && !reachable.contains(id))
        .toList();
    if (unreachable.isEmpty) return;
    for (final id in unreachable) {
      store.delete(id);
      _lru?.remove(id);
    }
    _scheduleNotify();
  }

  /// Removes everything, including optimistic data.
  void clear() {
    _generation++;
    store.clear();
    _lru?.clear();
    _optimisticLayers.clear();
    _scheduleNotify();
  }

  // Freshness -----------------------------------------------------------------

  /// When the result of [request] was last written (by a network response
  /// or [writeQuery]), or null if never.
  DateTime? writtenAt(GraphQLRequest request) {
    final millis = store.get(_writeTimesId)?[_writeTimeKey(request)];
    return millis is int ? DateTime.fromMillisecondsSinceEpoch(millis) : null;
  }

  /// Whether the cached result of [request] is older than [maxAge].
  ///
  /// Always false when [maxAge] is null. True when the result was never
  /// written through [request] (for example, it was assembled from other
  /// queries' data).
  bool isStale(GraphQLRequest request, Duration? maxAge) {
    if (maxAge == null) return false;
    final written = writtenAt(request);
    return written == null || _clock().difference(written) > maxAge;
  }

  void _recordWriteTime(GraphQLRequest request) {
    final times = {...?store.get(_writeTimesId)};
    times[_writeTimeKey(request)] = _clock().millisecondsSinceEpoch;
    if (times.length > _maxWriteTimes) {
      final oldest = times.entries.toList()
        ..sort((a, b) => (a.value as int).compareTo(b.value as int));
      for (final entry in oldest.take(times.length - _maxWriteTimes)) {
        times.remove(entry.key);
      }
    }
    store.put(_writeTimesId, times);
  }

  static String _writeTimeKey(GraphQLRequest request) =>
      sha1.convert(utf8.encode(request.identity)).toString();

  // Optimistic updates -------------------------------------------------------

  /// Applies [update] as an optimistic layer identified by [layerId].
  ///
  /// Writes made inside [update] are visible to optimistic reads until
  /// [removeOptimistic] is called with the same id.
  void recordOptimistic(
      Object layerId, void Function(GraphQLCache cache) update) {
    final layer = <String, JsonMap?>{};
    _optimisticLayers[layerId] = layer;
    final previous = _writingLayer;
    _writingLayer = layer;
    try {
      update(this);
    } catch (_) {
      _optimisticLayers.remove(layerId);
      rethrow;
    } finally {
      _writingLayer = previous;
    }
    _scheduleNotify();
  }

  /// Discards the optimistic layer [layerId].
  void removeOptimistic(Object layerId) {
    if (_optimisticLayers.remove(layerId) != null) _scheduleNotify();
  }

  /// Whether [data] (an optimistic read of [request]) differs from what the
  /// confirmed cache holds, i.e. it includes unconfirmed optimistic changes.
  bool isOptimistic(GraphQLRequest request, JsonMap data) {
    if (_optimisticLayers.isEmpty) return false;
    return !_equality.equals(readQuery(request, optimistic: false), data);
  }

  static const _equality = DeepCollectionEquality();

  /// Completes when the store has persisted every change so far.
  Future<void> flush() => store.flush();

  /// Flushes the store and stops notifying listeners.
  Future<void> close() async {
    await _changes.close();
    await store.close();
  }

  // Internals ----------------------------------------------------------------

  /// Reads [id] from the store, overlaid field by field with every
  /// optimistic layer when [optimistic] is true.
  JsonMap? _read(String id, {required bool optimistic}) {
    var entity = store.get(id);
    if (entity != null) _lru?.touch(id);
    if (!optimistic || _optimisticLayers.isEmpty) return entity;
    for (final layer in _optimisticLayers.values) {
      if (!layer.containsKey(id)) continue;
      final changes = layer[id];
      entity = changes == null ? null : {...?entity, ...changes};
    }
    return entity;
  }

  /// Writes to the store, or (inside [recordOptimistic]) records only the
  /// fields that differ from the current optimistic view, so removing one
  /// layer never leaves another layer holding its data.
  void _write(String id, JsonMap? value) {
    final layer = _writingLayer;
    if (layer == null) {
      store.put(id, value);
      if (value == null) {
        _lru?.remove(id);
      } else {
        _lru?.touch(id);
      }
      return;
    }
    if (value == null) {
      layer[id] = null;
      return;
    }
    final current = _read(id, optimistic: true) ?? const <String, dynamic>{};
    final changed = {
      for (final MapEntry(:key, :value) in value.entries)
        if (!current.containsKey(key) || !_equality.equals(current[key], value))
          key: value,
    };
    layer[id] = {...?layer[id], ...changed};
  }

  /// Deletes the least recently used entities past `maxEntities`.
  void _evictOverflow() {
    if (_writingLayer != null) return; // Optimistic writes add no entities.
    _lru?.takeOverflow().forEach(store.delete);
  }

  void _scheduleNotify() {
    if (_notifyScheduled || _changes.isClosed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_changes.isClosed) _changes.add(null);
    });
  }

  static GraphQLRequest _request(
    String document,
    JsonMap variables,
    String? operationName,
  ) =>
      GraphQLRequest(
        document: GraphQLDocument.parse(document, operationName: operationName),
        variables: variables,
      );

  static final _fragments = <String, ast.DocumentNode>{};

  static ast.DocumentNode _parseFragment(String source) {
    final cached = _fragments[source];
    if (cached != null) return cached;
    try {
      final document = gql.parseString(source);
      if (_fragments.length > 128) _fragments.clear();
      return _fragments[source] = document;
    } on SourceSpanException catch (e, stackTrace) {
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'Invalid fragment: $e',
        cause: e,
        stackTrace: stackTrace,
      );
    }
  }
}
