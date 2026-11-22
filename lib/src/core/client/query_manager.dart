import 'dart:async';

import '../cache/graphql_cache.dart';
import '../json.dart';
import '../request/cancellation_token.dart';
import '../request/graphql_document.dart';
import '../request/graphql_request.dart';
import '../request/policies.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';
import '../response/graphql_result.dart';
import '../transport/graphql_transport.dart';
import 'graphql_observer.dart';
import 'observable_query.dart';
import 'offline_queue.dart';
import 'result_mapper.dart';

/// Updates the cache after a mutation. [data] is the mutation's result data
/// (or the optimistic response while the mutation is in flight).
typedef CacheUpdater = void Function(GraphQLCache cache, JsonMap data);

/// Executes operations against the transport and the cache.
///
/// Shared by `GraphQLClient` and [ObservableQuery]; not part of the public
/// API.
final class QueryManager {
  /// Creates a manager.
  ///
  /// Restores mutations queued offline before the last shutdown and starts
  /// sending them.
  QueryManager({
    required this.transport,
    required this.cache,
    required this.observers,
    RetryDelay? offlineRetryDelay,
  }) {
    observers.add(
      offlineQueue = OfflineQueue(
        cache: cache,
        send: fetch,
        retryDelay: offlineRetryDelay,
      ),
    );
  }

  /// Sends requests.
  final GraphQLTransport transport;

  /// Stores results.
  final GraphQLCache cache;

  /// Receive operation events.
  final List<GraphQLObserver> observers;

  /// Mutations waiting for the network (`queueIfOffline`).
  late final OfflineQueue offlineQueue;

  final Map<String, Future<GraphQLResponse>> _inflight = {};
  final Set<ObservableQuery<Object?>> _watched = {};
  int _optimisticIds = 0;
  bool _appVisible = true;
  bool _online = true;

  /// Whether the app is in the foreground (see [setAppVisible]).
  bool get isAppVisible => _appVisible;

  /// Whether the device is believed to be online (see [setOnline]).
  bool get isOnline => _online;

  /// Whether watched queries may poll and refresh: the app is visible and
  /// online.
  bool get isActive => _appVisible && _online;

  /// Records whether the app is visible. See [_setActivity].
  Future<void> setAppVisible(bool visible) =>
      _setActivity(visible: visible, online: _online);

  /// Records whether the device is online. See [_setActivity].
  Future<void> setOnline(bool online) =>
      _setActivity(visible: _appVisible, online: online);

  /// Pauses watched queries' polling when the client becomes inactive, and
  /// refreshes them (as if they had just started) when it becomes active
  /// again.
  Future<void> _setActivity({
    required bool visible,
    required bool online,
  }) async {
    final wasActive = isActive;
    _appVisible = visible;
    _online = online;
    offlineQueue.setPaused(!online);
    if (wasActive == isActive) return;

    final queries = _watched.toList();
    if (!isActive) {
      for (final query in queries) {
        query.suspend();
      }
      return;
    }
    await Future.wait(queries.map((query) => query.revalidate()));
  }

  /// Currently watched queries.
  Iterable<ObservableQuery<Object?>> get watched => _watched;

  /// Registers a watched query so it can be refetched by name.
  void register(ObservableQuery<Object?> query) => _watched.add(query);

  /// Unregisters a watched query.
  void unregister(ObservableQuery<Object?> query) => _watched.remove(query);

  /// Sends [request] over the network.
  ///
  /// Identical queries in flight at the same time share one request, unless
  /// a [cancelToken] is given (cancelling must not affect other callers).
  Future<GraphQLResponse> fetch(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) {
    final canShare =
        cancelToken == null && request.type == GraphQLOperationType.query;
    if (!canShare) return _send(request, cancelToken);

    final key = request.identity;
    // The callback must not return the removed value: it is this same
    // future, and whenComplete would wait for it, deadlocking.
    return _inflight[key] ??= _send(request, null).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<GraphQLResponse> _send(
    GraphQLRequest request,
    CancellationToken? cancelToken,
  ) async {
    if (cancelToken?.isCancelled ?? false) {
      throw GraphQLException(
        GraphQLErrorKind.cancelled,
        'The request was cancelled before it was sent',
        operationName: request.operationName,
      );
    }
    final watch = Stopwatch()..start();
    observers.notify((o) => o.onRequest(request));
    try {
      final response =
          await transport.execute(request, cancelToken: cancelToken);
      observers.notify((o) => o.onResponse(request, response, watch.elapsed));
      return response;
    } catch (e, stackTrace) {
      final exception = ResultMapper.toException(e, stackTrace, request);
      observers.notify((o) => o.onError(request, exception, watch.elapsed));
      throw exception;
    }
  }

  /// Runs a query once according to [fetchPolicy].
  ///
  /// With [maxAge], cached data older than that is stale: `cacheFirst`
  /// fetches instead (returning the stale data if the network is
  /// unreachable), and `cacheAndNetwork` only refreshes stale data.
  Future<GraphQLResult<T>> query<T>(
    GraphQLRequest request, {
    required FetchPolicy fetchPolicy,
    required ErrorPolicy errorPolicy,
    DataParser<T>? parse,
    CancellationToken? cancelToken,
    Duration? maxAge,
  }) async {
    GraphQLResult<T>? stale;
    if (fetchPolicy
        case FetchPolicy.cacheFirst ||
            FetchPolicy.cacheAndNetwork ||
            FetchPolicy.cacheOnly) {
      final cached = readCache(request, parse);
      final isStale = cached != null && cache.isStale(request, maxAge);
      if (cached != null && fetchPolicy == FetchPolicy.cacheFirst && isStale) {
        stale = cached; // Fetch below; fall back to it if offline.
      } else if (cached != null) {
        if (fetchPolicy == FetchPolicy.cacheAndNetwork &&
            (maxAge == null || isStale)) {
          // Refresh in the background; watchers see the update via the cache.
          // _networkResult never throws: failures become GraphQLFailure.
          unawaited(_networkResult<T>(
            request,
            fetchPolicy: fetchPolicy,
            errorPolicy: errorPolicy,
            parse: parse,
          ));
        }
        return cached;
      } else if (fetchPolicy == FetchPolicy.cacheOnly) {
        return GraphQLFailure(GraphQLException(
          GraphQLErrorKind.cacheMiss,
          'No complete data in the cache for '
          '${request.operationName ?? 'this query'}',
          operationName: request.operationName,
        ));
      }
    }
    final result = await _networkResult(
      request,
      fetchPolicy: fetchPolicy,
      errorPolicy: errorPolicy,
      parse: parse,
      cancelToken: cancelToken,
    );
    // Stale-if-error: old data beats no data when the server is unreachable.
    if (stale != null &&
        result is GraphQLFailure<T> &&
        result.exception.kind.isTransient) {
      return stale;
    }
    return result;
  }

  /// Reads [request] from the cache. Returns null on a miss.
  GraphQLResult<T>? readCache<T>(GraphQLRequest request, DataParser<T>? parse) {
    final data = cache.readQuery(request);
    if (data == null) return null;
    observers.notify((o) => o.onCacheHit(request));
    return ResultMapper.fromData(
      data,
      request,
      parse: parse,
      source: cache.isOptimistic(request, data)
          ? ResultSource.optimistic
          : ResultSource.cache,
    );
  }

  Future<GraphQLResult<T>> _networkResult<T>(
    GraphQLRequest request, {
    required FetchPolicy fetchPolicy,
    required ErrorPolicy errorPolicy,
    DataParser<T>? parse,
    CancellationToken? cancelToken,
  }) async {
    try {
      final generation = cache.generation;
      final response = await fetch(request, cancelToken: cancelToken);
      if (fetchPolicy != FetchPolicy.noCache) {
        writeResponse(request, response, errorPolicy, generation);
      }
      return ResultMapper.fromResponse(
        response,
        request,
        errorPolicy: errorPolicy,
        parse: parse,
      );
    } catch (e, stackTrace) {
      return GraphQLFailure(ResultMapper.toException(e, stackTrace, request));
    }
  }

  /// Writes [response] to the cache if it is cacheable and the cache has not
  /// been cleared since the request started ([generation]).
  ///
  /// Returns whether it was written.
  bool writeResponse(
    GraphQLRequest request,
    GraphQLResponse response,
    ErrorPolicy errorPolicy,
    int generation,
  ) {
    if (generation != cache.generation ||
        !ResultMapper.isCacheable(response, errorPolicy)) {
      return false;
    }
    cache.writeQuery(request, response.data!);
    return true;
  }

  /// Drops shared in-flight requests so later calls start fresh ones, e.g.
  /// after the user changes.
  void clearInflight() => _inflight.clear();

  /// Runs a mutation, applying [optimisticResponse] while it is in flight.
  ///
  /// With [queueIfOffline], the mutation goes through [offlineQueue]: it
  /// waits there (optimistic data still applied) while the server is
  /// unreachable. [cancelToken] does not apply to queued mutations.
  ///
  /// An exception thrown by [update] is reported to the current [Zone]
  /// rather than turning a mutation the server accepted into a failure.
  Future<GraphQLResult<T>> mutate<T>(
    GraphQLRequest request, {
    required ErrorPolicy errorPolicy,
    DataParser<T>? parse,
    CancellationToken? cancelToken,
    JsonMap? optimisticResponse,
    CacheUpdater? update,
    List<String> refetchQueries = const [],
    bool queueIfOffline = false,
  }) async {
    final layerId = 'mutation-${++_optimisticIds}';
    if (optimisticResponse != null) {
      _guardUserCode(() => cache.recordOptimistic(layerId, (c) {
            c.writeQuery(request, optimisticResponse);
            update?.call(c, optimisticResponse);
          }));
    }

    final generation = cache.generation;
    final GraphQLResponse response;
    try {
      response = queueIfOffline
          ? await offlineQueue.enqueue(
              request,
              optimisticResponse: optimisticResponse,
            )
          : await fetch(request, cancelToken: cancelToken);
    } catch (e, stackTrace) {
      return GraphQLFailure(ResultMapper.toException(e, stackTrace, request));
    } finally {
      cache.removeOptimistic(layerId);
    }

    _guardUserCode(() {
      if (writeResponse(request, response, errorPolicy, generation)) {
        update?.call(cache, response.data!);
      }
    });
    final result = ResultMapper.fromResponse(
      response,
      request,
      errorPolicy: errorPolicy,
      parse: parse,
    );

    if (result.isSuccess && refetchQueries.isNotEmpty) {
      await refetch(refetchQueries);
    }
    return result;
  }

  static void _guardUserCode(void Function() body) {
    try {
      body();
    } catch (e, stackTrace) {
      Zone.current.handleUncaughtError(e, stackTrace);
    }
  }

  /// Runs a subscription. Results with data are written to the cache.
  Stream<GraphQLResult<T>> subscribe<T>(
    GraphQLRequest request, {
    required ErrorPolicy errorPolicy,
    DataParser<T>? parse,
  }) {
    return transport.subscribe(request).transform(
          StreamTransformer.fromHandlers(
            handleData: (response, sink) {
              try {
                writeResponse(request, response, errorPolicy, cache.generation);
              } catch (e, stackTrace) {
                sink.add(GraphQLFailure(
                  ResultMapper.toException(e, stackTrace, request),
                ));
                return;
              }
              sink.add(ResultMapper.fromResponse(
                response,
                request,
                errorPolicy: errorPolicy,
                parse: parse,
              ));
            },
            handleError: (error, stackTrace, sink) {
              sink.add(GraphQLFailure(
                ResultMapper.toException(error, stackTrace, request),
              ));
            },
          ),
        );
  }

  /// Refetches watched queries whose operation name is in [operationNames].
  Future<void> refetch(List<String> operationNames) async {
    final targets = _watched
        .where((q) => operationNames.contains(q.request.operationName))
        .toList();
    await Future.wait(targets.map((q) => q.refetch()));
  }

  /// Refetches every watched query.
  Future<void> refetchAll() async {
    await Future.wait(_watched.toList().map((q) => q.refetch()));
  }
}
