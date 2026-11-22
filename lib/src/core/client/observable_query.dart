import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../json.dart';
import '../request/graphql_request.dart';
import '../request/policies.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_result.dart';
import 'query_manager.dart';
import 'result_mapper.dart';

/// Merges a page from `fetchMore` into the data loaded so far.
typedef FetchMoreMerge = JsonMap Function(JsonMap previous, JsonMap more);

/// A query whose results are delivered as a stream and kept up to date
/// with the cache.
///
/// Listening starts it; it keeps emitting when the cache changes (for
/// example after a mutation updates an object it shows). It stops when its
/// last listener cancels, and can be listened to again later.
final class ObservableQuery<T> {
  /// Created by `GraphQLClient.watchQuery`.
  ObservableQuery(
    this._manager,
    this._request, {
    required this.fetchPolicy,
    required this.errorPolicy,
    this.parse,
    this.maxAge,
    Duration? pollInterval,
  }) : _pollInterval = pollInterval {
    _controller = StreamController<GraphQLResult<T>>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final QueryManager _manager;
  GraphQLRequest _request;

  /// How the cache is used.
  final FetchPolicy fetchPolicy;

  /// How errors alongside data are treated.
  final ErrorPolicy errorPolicy;

  /// Converts result data to [T].
  final DataParser<T>? parse;

  /// How long cached data counts as fresh. Stale data is still shown, then
  /// refreshed; fresh data is not refetched by `cacheAndNetwork`.
  final Duration? maxAge;

  late final StreamController<GraphQLResult<T>> _controller;
  StreamSubscription<void>? _cacheSubscription;
  Timer? _pollTimer;
  Duration? _pollInterval;
  GraphQLResult<T>? _latest;
  JsonMap? _latestData;
  bool _active = false;
  int _fetches = 0;
  bool _refetchedIncomplete = false;
  Future<GraphQLResult<T>>? _fetchingMore;

  static const _equality = DeepCollectionEquality();

  /// The current request (its variables change with [setVariables]).
  GraphQLRequest get request => _request;

  /// Results: cached data, network data and later cache updates.
  Stream<GraphQLResult<T>> get stream => _controller.stream;

  /// The most recent result, or null before the first one.
  GraphQLResult<T>? get latest => _latest;

  /// Whether a network request is in flight.
  bool get isFetching => _fetches > 0;

  bool get _usesCache => fetchPolicy != FetchPolicy.noCache;

  /// Fetches from the network again, optionally with new [variables].
  ///
  /// The result is also emitted on [stream].
  Future<GraphQLResult<T>> refetch({JsonMap? variables}) {
    if (variables != null) _request = _request.withVariables(variables);
    return _fetchNetwork();
  }

  /// Replaces the variables and loads according to [fetchPolicy].
  Future<void> setVariables(JsonMap variables) async {
    _request = _request.withVariables(variables);
    _latestData = null;
    _refetchedIncomplete = false;
    await _load();
  }

  /// Loads another page with [variables] (merged over the current ones) and
  /// combines it with the current data using [merge].
  ///
  /// Calls made while a page is loading return that same page instead of
  /// loading (and merging) it twice, which makes it safe to call from scroll
  /// listeners. Fails if called before the first result arrived.
  ///
  /// ```dart
  /// await query.fetchMore(
  ///   variables: {'after': endCursor},
  ///   merge: (previous, more) => {
  ///     'posts': [...previous['posts'], ...more['posts']],
  ///   },
  /// );
  /// ```
  Future<GraphQLResult<T>> fetchMore({
    JsonMap variables = const {},
    required FetchMoreMerge merge,
  }) =>
      _fetchingMore ??= _fetchMore(variables, merge).whenComplete(() {
        _fetchingMore = null;
      });

  Future<GraphQLResult<T>> _fetchMore(
    JsonMap variables,
    FetchMoreMerge merge,
  ) async {
    final previous = _latestData;
    if (previous == null) {
      return GraphQLFailure(GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'fetchMore was called before the first result arrived',
        operationName: _request.operationName,
      ));
    }
    final request = _request;
    final pageRequest =
        request.withVariables({...request.variables, ...variables});
    final generation = _manager.cache.generation;
    try {
      final response = await _manager.fetch(pageRequest);
      final page = ResultMapper.fromResponse<JsonMap>(
        response,
        pageRequest,
        errorPolicy: errorPolicy,
      );
      switch (page) {
        case GraphQLFailure(:final exception):
          return GraphQLFailure(exception);
        case GraphQLSuccess(data: final more):
          final merged = merge(_latestData ?? previous, more);
          if (_usesCache && generation == _manager.cache.generation) {
            _manager.cache.writeQuery(request, merged);
          }
          return _emitData(merged, ResultSource.network);
      }
    } catch (e, stackTrace) {
      return GraphQLFailure(
          ResultMapper.toException(e, stackTrace, pageRequest));
    }
  }

  /// Refetches every [interval] while listened to.
  void startPolling(Duration interval) {
    _pollInterval = interval;
    if (_active) _schedulePolling();
  }

  /// Stops polling.
  void stopPolling() {
    _pollInterval = null;
    _pollTimer?.cancel();
  }

  /// Pauses polling while the app is hidden or offline. Called by the
  /// client.
  @internal
  void suspend() => _pollTimer?.cancel();

  /// Resumes polling and refreshes the data if [fetchPolicy] would fetch on
  /// start (polling queries always refresh). Called by the client when the
  /// app becomes visible and online again.
  @internal
  Future<void> revalidate() async {
    if (!_active) return;
    _schedulePolling();
    if (isFetching) return;
    final cacheHit = _usesCache && _manager.cache.readQuery(_request) != null;
    if (_pollInterval != null || _needsNetwork(cacheHit: cacheHit)) {
      await _fetchNetwork();
    }
  }

  /// Stops watching and closes [stream].
  Future<void> close() async {
    _stop();
    await _controller.close();
  }

  // Lifecycle ----------------------------------------------------------------

  void _start() {
    _active = true;
    _manager.register(this);
    if (_usesCache) {
      _cacheSubscription =
          _manager.cache.changes.listen((_) => _onCacheChanged());
    }
    _schedulePolling();
    unawaited(_load());
  }

  void _stop() {
    _active = false;
    _manager.unregister(this);
    unawaited(_cacheSubscription?.cancel());
    _cacheSubscription = null;
    _pollTimer?.cancel();
  }

  Future<void> _load() async {
    final cacheHit = switch (fetchPolicy) {
      FetchPolicy.cacheFirst ||
      FetchPolicy.cacheAndNetwork ||
      FetchPolicy.cacheOnly =>
        _emitFromCache(),
      FetchPolicy.networkOnly || FetchPolicy.noCache => false,
    };
    if (_needsNetwork(cacheHit: cacheHit)) {
      await _fetchNetwork();
    } else if (!cacheHit) {
      _emit(GraphQLFailure(GraphQLException(
        GraphQLErrorKind.cacheMiss,
        'No complete data in the cache for '
        '${_request.operationName ?? 'this query'}',
        operationName: _request.operationName,
      )));
    }
  }

  /// Whether loading must go to the network, given whether the cache had a
  /// complete result.
  bool _needsNetwork({required bool cacheHit}) => switch (fetchPolicy) {
        FetchPolicy.cacheFirst => !cacheHit || _isStale,
        FetchPolicy.cacheAndNetwork => !cacheHit || maxAge == null || _isStale,
        FetchPolicy.networkOnly || FetchPolicy.noCache => true,
        FetchPolicy.cacheOnly => false,
      };

  bool get _isStale => _manager.cache.isStale(_request, maxAge);

  void _schedulePolling() {
    _pollTimer?.cancel();
    final interval = _pollInterval;
    if (interval == null || !_manager.isActive) return;
    _pollTimer = Timer.periodic(interval, (_) {
      if (!isFetching) unawaited(_fetchNetwork());
    });
  }

  // Data flow ----------------------------------------------------------------

  Future<GraphQLResult<T>> _fetchNetwork() async {
    _fetches++;
    final request = _request;
    try {
      final generation = _manager.cache.generation;
      final response = await _manager.fetch(request);
      if (_usesCache) {
        _manager.writeResponse(request, response, errorPolicy, generation);
      }
      if (!identical(request, _request)) return _latest ?? _superseded();

      final result = ResultMapper.fromResponse(
        response,
        request,
        errorPolicy: errorPolicy,
        parse: parse,
      );
      _refetchedIncomplete = false;
      if (result is GraphQLSuccess<T>) {
        // Unchanged data (e.g. polling) is returned but not re-emitted.
        final unchanged = _latest is GraphQLSuccess<T> &&
            _equality.equals(response.data, _latestData);
        _latestData = response.data;
        if (unchanged) return _latest = result;
      }
      return _emit(result);
    } catch (e, stackTrace) {
      return _emit(
          GraphQLFailure(ResultMapper.toException(e, stackTrace, request)));
    } finally {
      _fetches--;
    }
  }

  /// Emits cached data if the cache has a complete result.
  bool _emitFromCache() {
    final data = _manager.cache.readQuery(_request);
    if (data == null) return false;
    _emitData(data, _sourceOf(data));
    return true;
  }

  void _onCacheChanged() {
    if (!_active) return;
    final data = _manager.cache.readQuery(_request);
    if (data == null) {
      // An object this query shows was evicted. Refetch once; never loop.
      final canRefetch = fetchPolicy == FetchPolicy.cacheFirst ||
          fetchPolicy == FetchPolicy.cacheAndNetwork;
      if (canRefetch &&
          _latestData != null &&
          !_refetchedIncomplete &&
          !isFetching) {
        _refetchedIncomplete = true;
        unawaited(_fetchNetwork());
      }
      return;
    }
    if (_equality.equals(data, _latestData)) return;
    _emitData(data, _sourceOf(data));
  }

  ResultSource _sourceOf(JsonMap data) =>
      _manager.cache.isOptimistic(_request, data)
          ? ResultSource.optimistic
          : ResultSource.cache;

  GraphQLResult<T> _emitData(JsonMap data, ResultSource source) {
    _latestData = data;
    return _emit(
        ResultMapper.fromData(data, _request, parse: parse, source: source));
  }

  GraphQLResult<T> _emit(GraphQLResult<T> result) {
    _latest = result;
    if (!_controller.isClosed) _controller.add(result);
    return result;
  }

  GraphQLResult<T> _superseded() => GraphQLFailure(GraphQLException(
        GraphQLErrorKind.cancelled,
        'Superseded by a request with newer variables',
        operationName: _request.operationName,
      ));
}
