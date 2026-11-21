import 'package:dio/dio.dart';

import '../cache/graphql_cache.dart';
import '../devtools/devtools_bridge.dart';
import '../json.dart';
import '../request/cancellation_token.dart';
import '../request/graphql_document.dart';
import '../request/graphql_request.dart';
import '../request/policies.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_result.dart';
import '../transport/credential_policy.dart';
import '../transport/graphql_transport.dart';
import '../transport/http/http_transport.dart';
import '../transport/http/interceptors/auth_interceptor.dart';
import '../transport/http/interceptors/logging_interceptor.dart';
import '../transport/http/interceptors/retry_interceptor.dart';
import '../transport/http/request_batcher.dart';
import '../transport/websocket/subscription_protocol.dart';
import '../transport/websocket/websocket_transport.dart';
import 'graphql_observer.dart';
import 'observable_query.dart';
import 'query_manager.dart';
import 'result_mapper.dart';

/// The entry point: runs queries, mutations and subscriptions.
///
/// ```dart
/// final client = GraphQLClient(
///   'https://api.example.com/graphql',
///   token: () => auth.accessToken,
/// );
///
/// final result = await client.query(
///   r'query User($id: ID!) { user(id: $id) { id name } }',
///   variables: {'id': '1'},
///   parse: (data) => User.fromJson(data['user']),
/// );
/// ```
///
/// Operations never throw for request failures: they return a
/// [GraphQLFailure] describing what went wrong.
final class GraphQLClient {
  /// Creates a client for [endpoint] with sensible defaults.
  ///
  /// - [subscriptionEndpoint]: `ws://` or `wss://` URL for subscriptions.
  /// - [token] / [refreshToken]: adds `Authorization: Bearer <token>` and
  ///   refreshes it on HTTP 401 or `UNAUTHENTICATED`; the token is also sent
  ///   in the WebSocket `connection_init` payload (read again on reconnect).
  ///   Credentials are only sent over https/wss or to local/private hosts
  ///   unless [allowInsecureAuth] is true.
  /// - [subscriptionConnectionParams]: replaces the default
  ///   `connection_init` payload (`{'Authorization': 'Bearer <token>'}`).
  ///   HTTP [headers] are not sent over the WebSocket.
  /// - [cache]: defaults to an in-memory normalized cache.
  /// - [defaultMaxAge]: how long cached results count as fresh (see
  ///   `query(maxAge:)`); null means they never go stale.
  /// - [maxRetries]: retries for network errors, timeouts, 429 and 5xx
  ///   (never for mutations).
  /// - [persistedQueries]: enables Automatic Persisted Queries.
  /// - [useGetForQueries]: sends queries as GET (CDN-cacheable).
  /// - [batch]: sends queries started close together as one HTTP request
  ///   (the server must support batching; otherwise it falls back).
  /// - [logging] / [logger]: logs operations with credentials redacted.
  /// - [interceptors]: extra Dio interceptors, run after the built-in ones.
  /// - [httpClientAdapter]: custom Dio adapter (pinning, proxies, tests).
  factory GraphQLClient(
    String endpoint, {
    String? subscriptionEndpoint,
    Map<String, String> headers = const {},
    TokenProvider? token,
    TokenRefresher? refreshToken,
    void Function(Object? error)? onRefreshFailed,
    bool allowInsecureAuth = false,
    ConnectionParamsProvider? subscriptionConnectionParams,
    GraphQLCache? cache,
    FetchPolicy defaultFetchPolicy = FetchPolicy.cacheFirst,
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,
    Duration? defaultMaxAge,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 2,
    bool persistedQueries = false,
    bool useGetForQueries = false,
    BatchOptions? batch,
    bool addTypename = true,
    SubscriptionProtocol subscriptionProtocol =
        SubscriptionProtocol.graphqlTransportWs,
    bool logging = false,
    void Function(String message)? logger,
    List<Interceptor> interceptors = const [],
    HttpClientAdapter? httpClientAdapter,
    List<GraphQLObserver> observers = const [],
  }) {
    assert(
      refreshToken == null || token != null,
      'refreshToken has no effect without token',
    );
    final http = HttpTransport(
      endpoint,
      headers: headers,
      timeout: timeout,
      persistedQueries: persistedQueries,
      useGetForQueries: useGetForQueries,
      batch: batch,
      httpClientAdapter: httpClientAdapter,
      interceptors: [
        if (token != null)
          AuthInterceptor(
            token: token,
            refreshToken: refreshToken,
            onRefreshFailed: onRefreshFailed,
            allowInsecureAuth: allowInsecureAuth,
          ),
        if (maxRetries > 0) RetryInterceptor(maxRetries: maxRetries),
        if (logging || logger != null) LoggingInterceptor(logger: logger),
        ...interceptors,
      ],
    );

    final GraphQLTransport transport = subscriptionEndpoint == null
        ? http
        : SplitTransport(
            operations: http,
            subscriptions: WebSocketTransport(
              subscriptionEndpoint,
              protocol: subscriptionProtocol,
              connectionTimeout: timeout,
              connectionParams: subscriptionConnectionParams ??
                  _tokenConnectionParams(
                    Uri.parse(subscriptionEndpoint),
                    token,
                    allowInsecureAuth: allowInsecureAuth,
                  ),
            ),
          );

    return GraphQLClient.custom(
      transport: transport,
      cache: cache,
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      defaultMaxAge: defaultMaxAge,
      addTypename: addTypename,
      observers: observers,
    );
  }

  /// Creates a client over any [transport], e.g. a custom one or
  /// `MockTransport` in tests.
  GraphQLClient.custom({
    required GraphQLTransport transport,
    GraphQLCache? cache,
    this.defaultFetchPolicy = FetchPolicy.cacheFirst,
    this.defaultErrorPolicy = ErrorPolicy.none,
    this.defaultMaxAge,
    this.addTypename = true,
    List<GraphQLObserver> observers = const [],
  }) : _manager = QueryManager(
          transport: transport,
          cache: cache ?? GraphQLCache(),
          observers: [...observers],
        ) {
    if (devToolsEnabled) _attachDevTools(transport);
  }

  /// The default `connection_init` payload: just the bearer token, and only
  /// over a connection where sending it is safe.
  static ConnectionParamsProvider _tokenConnectionParams(
    Uri uri,
    TokenProvider? token, {
    required bool allowInsecureAuth,
  }) =>
      () async {
        final value = await token?.call();
        if (value == null || value.isEmpty) return const <String, dynamic>{};
        if (!allowInsecureAuth && !CredentialPolicy.isSafeForCredentials(uri)) {
          throw GraphQLException(
            GraphQLErrorKind.invalidRequest,
            CredentialPolicy.insecureMessage(uri),
          );
        }
        return {'Authorization': 'Bearer $value'};
      };

  /// Fetch policy for queries that do not pass one.
  final FetchPolicy defaultFetchPolicy;

  /// Error policy for operations that do not pass one.
  final ErrorPolicy defaultErrorPolicy;

  /// How long cached query results count as fresh, for queries that do not
  /// pass `maxAge`. Null means cached data never goes stale.
  final Duration? defaultMaxAge;

  /// Whether `__typename` is added to documents (needed for normalization).
  final bool addTypename;

  final QueryManager _manager;
  bool _isDisposed = false;
  int? _devToolsId;

  /// The normalized cache. Read, write or evict data directly.
  GraphQLCache get cache => _manager.cache;

  /// Runs a query once.
  ///
  /// Without [parse], the result data is the raw JSON map (use
  /// `client.query<JsonMap>(...)` or `dynamic`).
  ///
  /// [maxAge] treats older cached data as stale: `cacheFirst` then fetches
  /// (and still returns the stale data if the server is unreachable), and
  /// `cacheAndNetwork` only refreshes stale data.
  Future<GraphQLResult<T>> query<T>(
    String document, {
    JsonMap variables = const {},
    String? operationName,
    DataParser<T>? parse,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Duration? maxAge,
    Map<String, String> headers = const {},
    CancellationToken? cancelToken,
  }) async {
    final request = _requestOrFailure(
      document,
      variables,
      operationName,
      headers,
      GraphQLOperationType.query,
    );
    if (request is GraphQLFailure<GraphQLRequest>) {
      return GraphQLFailure(request.exception);
    }
    return _manager.query(
      request.dataOrThrow,
      fetchPolicy: fetchPolicy ?? defaultFetchPolicy,
      errorPolicy: errorPolicy ?? defaultErrorPolicy,
      parse: parse,
      cancelToken: cancelToken,
      maxAge: maxAge ?? defaultMaxAge,
    );
  }

  /// Runs a mutation.
  ///
  /// - [optimisticResponse]: data shown immediately (as if the server had
  ///   answered) and rolled back if the mutation fails.
  /// - [update]: edits the cache with the result, e.g. to add a created
  ///   item to a list. Also runs with the optimistic response.
  /// - [refetchQueries]: names of watched queries to refetch on success.
  Future<GraphQLResult<T>> mutate<T>(
    String document, {
    JsonMap variables = const {},
    String? operationName,
    DataParser<T>? parse,
    ErrorPolicy? errorPolicy,
    JsonMap? optimisticResponse,
    CacheUpdater? update,
    List<String> refetchQueries = const [],
    Map<String, String> headers = const {},
    CancellationToken? cancelToken,
  }) async {
    final request = _requestOrFailure(
      document,
      variables,
      operationName,
      headers,
      GraphQLOperationType.mutation,
    );
    if (request is GraphQLFailure<GraphQLRequest>) {
      return GraphQLFailure(request.exception);
    }
    return _manager.mutate(
      request.dataOrThrow,
      errorPolicy: errorPolicy ?? defaultErrorPolicy,
      parse: parse,
      cancelToken: cancelToken,
      optimisticResponse: optimisticResponse,
      update: update,
      refetchQueries: refetchQueries,
    );
  }

  /// Watches a query: emits cached data, network data and every later
  /// cache change that affects it.
  ///
  /// Listening to [ObservableQuery.stream] starts the query.
  ObservableQuery<T> watchQuery<T>(
    String document, {
    JsonMap variables = const {},
    String? operationName,
    DataParser<T>? parse,
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    ErrorPolicy? errorPolicy,
    Duration? maxAge,
    Duration? pollInterval,
    Map<String, String> headers = const {},
  }) {
    _checkNotDisposed();
    return ObservableQuery<T>(
      _manager,
      _request(document, variables, operationName, headers,
          GraphQLOperationType.query),
      fetchPolicy: fetchPolicy,
      errorPolicy: errorPolicy ?? defaultErrorPolicy,
      parse: parse,
      maxAge: maxAge ?? defaultMaxAge,
      pollInterval: pollInterval,
    );
  }

  /// Starts a subscription. Each event is a [GraphQLResult]; cancel the
  /// stream subscription to stop it.
  Stream<GraphQLResult<T>> subscribe<T>(
    String document, {
    JsonMap variables = const {},
    String? operationName,
    DataParser<T>? parse,
    ErrorPolicy? errorPolicy,
  }) {
    final request = _requestOrFailure(
      document,
      variables,
      operationName,
      const {},
      GraphQLOperationType.subscription,
    );
    return switch (request) {
      GraphQLFailure(:final exception) =>
        Stream.value(GraphQLFailure<T>(exception)),
      GraphQLSuccess(data: final request) => _manager.subscribe(
          request,
          errorPolicy: errorPolicy ?? defaultErrorPolicy,
          parse: parse,
        ),
    };
  }

  /// Refetches watched queries by operation name.
  Future<void> refetchQueries(List<String> operationNames) =>
      _manager.refetch(operationNames);

  /// Clears the cache and refetches every watched query, e.g. after the
  /// user signs out and in as someone else.
  ///
  /// Completes after the cleared cache has been persisted, so no data from
  /// the previous user remains on disk.
  Future<void> resetStore() async {
    _manager.clearInflight();
    cache.clear();
    await cache.flush();
    await _manager.refetchAll();
  }

  /// Closes connections and the cache. The client cannot be used afterwards.
  Future<void> dispose() async {
    if (_devToolsId case final id?) DevToolsBridge.instance.unregister(id);
    if (_isDisposed) return;
    _isDisposed = true;
    for (final query in _manager.watched.toList()) {
      await query.close();
    }
    await _manager.transport.dispose();
    await cache.close();
  }

  // Helpers ------------------------------------------------------------------

  /// Shows this client in Dart DevTools (debug and profile builds only).
  void _attachDevTools(GraphQLTransport transport) {
    final id = DevToolsBridge.instance.register(
      _ClientDevToolsTarget(this, _describe(transport)),
    );
    _devToolsId = id;
    _manager.observers.add(DevToolsObserver(id));
  }

  static String _describe(GraphQLTransport transport) => switch (transport) {
        HttpTransport(:final endpoint) => endpoint,
        SplitTransport(:final operations) => _describe(operations),
        _ => transport.runtimeType.toString(),
      };

  GraphQLResult<GraphQLRequest> _requestOrFailure(
    String document,
    JsonMap variables,
    String? operationName,
    Map<String, String> headers,
    GraphQLOperationType expected,
  ) {
    try {
      _checkNotDisposed();
      return GraphQLSuccess(
          _request(document, variables, operationName, headers, expected));
    } on GraphQLException catch (e) {
      return GraphQLFailure(e);
    }
  }

  GraphQLRequest _request(
    String document,
    JsonMap variables,
    String? operationName,
    Map<String, String> headers,
    GraphQLOperationType expected,
  ) {
    final parsed = GraphQLDocument.parse(
      document,
      operationName: operationName,
      addTypename: addTypename,
    );
    if (parsed.type != expected) {
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'Expected a ${expected.name} but the document contains a '
        '${parsed.type.name}. Use client.${_methodFor(parsed.type)}() instead.',
        operationName: parsed.operationName,
      );
    }
    return GraphQLRequest(
      document: parsed,
      variables: variables,
      headers: headers,
    );
  }

  static String _methodFor(GraphQLOperationType type) => switch (type) {
        GraphQLOperationType.query => 'query',
        GraphQLOperationType.mutation => 'mutate',
        GraphQLOperationType.subscription => 'subscribe',
      };

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw const GraphQLException(
        GraphQLErrorKind.unknown,
        'This GraphQLClient has been disposed.',
      );
    }
  }
}

final class _ClientDevToolsTarget implements DevToolsTarget {
  _ClientDevToolsTarget(this._client, this.label);

  final GraphQLClient _client;

  @override
  final String label;

  /// Entities only: ids starting with `$` are the cache's own bookkeeping.
  @override
  Map<String, JsonMap?> cacheSnapshot() {
    final store = _client.cache.store;
    return {
      for (final id in store.keys)
        if (!id.startsWith(r'$')) id: store.get(id),
    };
  }

  @override
  void clearCache() => _client.cache.clear();
}
