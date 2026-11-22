import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../cache/graphql_cache.dart';
import '../json.dart';
import '../request/graphql_document.dart';
import '../request/graphql_request.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';
import 'graphql_observer.dart';

/// Sends one request, throwing a [GraphQLException] on failure.
typedef RequestSender = Future<GraphQLResponse> Function(
  GraphQLRequest request,
);

/// How long to wait before the [attempt]th automatic retry (1-based).
typedef RetryDelay = Duration Function(int attempt);

/// Mutations made with `queueIfOffline: true` that wait for the network.
///
/// They are saved in the cache's store (so they survive restarts, encrypted
/// if the store uses a codec) and sent one at a time, in order. A mutation
/// stays queued only while the server cannot be reached; any other outcome
/// (success or an error from the server) removes it.
///
/// The queue retries when the client comes back online
/// (`GraphQLClient.setOnline`), when the app returns to the foreground,
/// after any successful request, and on a backoff timer.
///
/// Mutations restored after a restart get their optimistic response back,
/// but not their `update` callback (code cannot be saved); the server's
/// answer still updates the normalized objects it returns.
///
/// Delivery is at least once: if the app is killed while a mutation is in
/// flight, it is sent again on the next start. Make queued mutations
/// idempotent (e.g. pass a client-generated id) when duplicates matter.
final class OfflineQueue extends GraphQLObserver {
  /// Created by the client; restores mutations saved in [cache].
  @internal
  OfflineQueue({
    required GraphQLCache cache,
    required RequestSender send,
    RetryDelay? retryDelay,
  })  : _cache = cache,
        _send = send,
        _retryDelay = retryDelay ?? _defaultRetryDelay {
    _restore();
  }

  /// Store entry holding the queue. Ids starting with `$` are never entities.
  static const _storeId = r'$offlineQueue';

  final GraphQLCache _cache;
  final RequestSender _send;
  final RetryDelay _retryDelay;
  final _items = <_QueuedMutation>[];
  final _changes = StreamController<int>.broadcast();
  Future<void>? _flushing;
  Timer? _retryTimer;
  int _failedAttempts = 0;
  int _nextId = 0;
  bool _paused = false;

  static Duration _defaultRetryDelay(int attempt) =>
      Duration(seconds: math.min(60, 1 << math.min(attempt, 6)));

  /// How many mutations are waiting.
  int get length => _items.length;

  /// Emits [length] whenever it changes, e.g. to show "3 changes waiting".
  Stream<int> get changes => _changes.stream;

  /// Sends the waiting mutations now.
  ///
  /// Completes when the queue is empty, or when the server is still
  /// unreachable (the rest stay queued).
  Future<void> flush() => _flushing ??= _drain().whenComplete(() {
        _flushing = null;
      });

  /// Discards every waiting mutation. Their calls complete with a
  /// [GraphQLErrorKind.cancelled] failure.
  Future<void> clear() async {
    final discarded = _items.toList();
    _items.clear();
    _retryTimer?.cancel();
    _save();
    for (final item in discarded) {
      _complete(item, error: _cancelled('The mutation was discarded'));
    }
  }

  // Client API ---------------------------------------------------------------

  /// Queues [request] and completes with the server's response once it has
  /// been delivered. Throws a [GraphQLException] if the server rejected it,
  /// or if it cannot be queued (variables that are not JSON, like files).
  @internal
  Future<GraphQLResponse> enqueue(
    GraphQLRequest request, {
    JsonMap? optimisticResponse,
  }) {
    if (!_isJson(request.variables)) {
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'queueIfOffline needs JSON variables; file uploads cannot be queued',
        operationName: request.operationName,
      );
    }
    final item = _QueuedMutation(
      id: _newId(),
      request: request,
      optimisticResponse: optimisticResponse,
      completer: Completer<GraphQLResponse>(),
    );
    _items.add(item);
    _save();
    if (!_paused) unawaited(flush());
    return item.completer!.future;
  }

  /// Stops sending while the device is offline; resuming sends the queue.
  @internal
  void setPaused(bool paused) {
    _paused = paused;
    if (paused) {
      _retryTimer?.cancel();
    } else if (_items.isNotEmpty) {
      unawaited(flush());
    }
  }

  /// Ends calls still waiting (their mutations stay saved for the next
  /// start) and stops retrying.
  @internal
  Future<void> close() async {
    _paused = true; // A send still in flight must not schedule a retry.
    _retryTimer?.cancel();
    for (final item in _items) {
      if (item.completer case final completer? when !completer.isCompleted) {
        completer.completeError(_cancelled(
          'The client was disposed; the mutation stays queued and is sent '
          'after the next start',
        ));
      }
    }
    await _changes.close();
  }

  /// A response arrived, so the server is reachable: send the queue.
  @override
  void onResponse(
    GraphQLRequest request,
    GraphQLResponse response,
    Duration elapsed,
  ) {
    if (_items.isNotEmpty && !_paused && _flushing == null) {
      unawaited(flush());
    }
  }

  // Delivery -----------------------------------------------------------------

  Future<void> _drain() async {
    _retryTimer?.cancel();
    while (_items.isNotEmpty && !_paused) {
      final item = _items.first;
      try {
        _end(item, response: await _send(item.request));
      } on GraphQLException catch (e) {
        if (e.kind == GraphQLErrorKind.network) {
          _scheduleRetry();
          return;
        }
        _end(item, error: e);
      }
    }
    _failedAttempts = 0;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_paused) return;
    _retryTimer = Timer(_retryDelay(++_failedAttempts), () {
      if (!_paused) unawaited(flush());
    });
  }

  /// Removes [item] and completes its call, unless it was already removed
  /// (by [clear] while it was in flight): then its late response is
  /// dropped, so it cannot land in a cache that was reset.
  void _end(
    _QueuedMutation item, {
    GraphQLResponse? response,
    GraphQLException? error,
  }) {
    if (!_items.remove(item)) return;
    _save();
    _complete(item, response: response, error: error);
  }

  /// Completes [item]'s call. Mutations restored after a restart have no
  /// caller, so their optimistic data and the server's answer are handled
  /// here.
  void _complete(
    _QueuedMutation item, {
    GraphQLResponse? response,
    GraphQLException? error,
  }) {
    final completer = item.completer;
    if (completer == null) {
      _cache.removeOptimistic(item.id);
      if (response case GraphQLResponse(:final data?, hasErrors: false)) {
        _cache.writeQuery(item.request, data);
      }
    } else if (!completer.isCompleted) {
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(response);
      }
    }
  }

  // Persistence --------------------------------------------------------------

  void _save() {
    if (_items.isEmpty) {
      _cache.store.delete(_storeId);
    } else {
      _cache.store.put(_storeId, {
        'mutations': [for (final item in _items) item.toJson()],
      });
    }
    if (!_changes.isClosed) _changes.add(_items.length);
  }

  void _restore() {
    final saved = _cache.store.get(_storeId)?['mutations'];
    if (saved is! List) return;
    for (final json in saved.whereType<JsonMap>()) {
      final item = _QueuedMutation.tryFromJson(json);
      if (item == null) continue; // Unreadable (e.g. an older format).
      _items.add(item);
      if (item.optimisticResponse case final optimistic?) {
        _cache.recordOptimistic(
          item.id,
          (cache) => cache.writeQuery(item.request, optimistic),
        );
      }
    }
    if (_items.isNotEmpty) unawaited(flush());
  }

  String _newId() =>
      'queued-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  static GraphQLException _cancelled(String message) =>
      GraphQLException(GraphQLErrorKind.cancelled, message);

  static bool _isJson(Object? value) => switch (value) {
        null || bool() || num() || String() => true,
        final List<Object?> list => list.every(_isJson),
        final Map<String, Object?> map => map.values.every(_isJson),
        _ => false,
      };
}

/// One waiting mutation. [completer] is null for mutations restored after a
/// restart, which no caller is waiting for.
final class _QueuedMutation {
  _QueuedMutation({
    required this.id,
    required this.request,
    this.optimisticResponse,
    this.completer,
  });

  static _QueuedMutation? tryFromJson(JsonMap json) {
    final (id, document, variables) =
        (json['id'], json['document'], json['variables']);
    if (id is! String || document is! String || variables is! JsonMap) {
      return null;
    }
    try {
      return _QueuedMutation(
        id: id,
        request: GraphQLRequest(
          document: GraphQLDocument.parse(
            document,
            operationName: json['operationName'] as String?,
            addTypename: false, // The saved document already has them.
          ),
          variables: variables,
        ),
        optimisticResponse: json['optimisticResponse'] as JsonMap?,
      );
    } on GraphQLException {
      return null;
    }
  }

  final String id;
  final GraphQLRequest request;
  final JsonMap? optimisticResponse;
  final Completer<GraphQLResponse>? completer;

  /// Headers are not saved: they may hold credentials, which the client
  /// adds again when the mutation is sent.
  JsonMap toJson() => {
        'id': id,
        'document': request.document.printed,
        'operationName': request.operationName,
        'variables': request.variables,
        if (optimisticResponse != null)
          'optimisticResponse': optimisticResponse,
      };
}
