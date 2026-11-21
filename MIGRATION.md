# Migrating from 1.x to 2.0

Version 2 is a redesign focused on simplicity and correctness. Version 1
injected an invalid `errors { ... }` selection into every query, so it did
not work with spec-compliant servers. Upgrading is strongly recommended.

## At a glance

| 1.x | 2.0 |
|---|---|
| `GraphQLClientBase(config: GraphQLConfig(endpoint: url, ...))` | `GraphQLClient(url, ...)` |
| `GraphQLConfig` (20 fields, 9 unused) | Named parameters on `GraphQLClient` |
| `Future<GraphQLResponse<T>>` + try/catch | `Future<GraphQLResult<T>>`, sealed: `GraphQLSuccess` / `GraphQLFailure` |
| `ErrorHandlingStrategy` (`throwError`, `silent`, ...) | Not needed: failures are values. Use `result.dataOrThrow` to throw. |
| `onError` callback | `GraphQLObserver.onError` |
| `CachePolicy` (11 values, 5 unimplemented) | `FetchPolicy` (5 values, all implemented) |
| `CacheManager` (per-query blobs with TTL) | `GraphQLCache` (normalized) + `Store` (`InMemoryStore`, `PersistentStore`) |
| `invalidateQueries([...])` | `cache.evict('Type:id')`, `client.refetchQueries([...])`, `client.resetStore()` |
| `subscriptionConnectionParams` | Sent automatically (headers + token); or `WebSocketTransport(connectionParams: ...)` |
| `batch(...)` | Removed (most servers don't support it) |
| `getSchema()` / `validateQuery()` | Removed; documents are validated with a real parser when used |
| `QueryTransformer`, `ResponseParser` | Removed (internal concerns) |
| `GraphQLRepositoryImpl`, `GraphQLSubscriptionRepository` | `HttpTransport`, `WebSocketTransport` |

## Client setup

```dart
// 1.x
final client = GraphQLClientBase(
  config: GraphQLConfig(
    endpoint: 'https://api.example.com/graphql',
    subscriptionEndpoint: 'wss://api.example.com/graphql',
    defaultHeaders: {'Authorization': 'Bearer $token'},
    defaultCachePolicy: CachePolicy.cacheFirst,
    maxRetries: 3,
    enableLogging: true,
  ),
  interceptors: [AuthInterceptor(getToken: getToken, refreshToken: refresh)],
);

// 2.0
final client = GraphQLClient(
  'https://api.example.com/graphql',
  subscriptionEndpoint: 'wss://api.example.com/graphql',
  token: getToken,
  refreshToken: refresh,
  maxRetries: 3,
  logging: true,
);
```

`cacheFirst` is the default fetch policy, so it no longer needs to be passed.

## Queries and errors

```dart
// 1.x
try {
  final response = await client.query<Map<String, dynamic>>(query, variables: vars);
  final user = User.fromJson(response.data!['user']);
} on GraphQLException catch (e) {
  showError(e.message);
}

// 2.0
final result = await client.query(
  query,
  variables: vars,
  parse: (data) => User.fromJson(data['user']),
);
switch (result) {
  case GraphQLSuccess(:final data): show(data);
  case GraphQLFailure(:final exception): showError(exception.userMessage);
}
```

## Mutations and the cache

```dart
// 1.x: manual invalidation by cache key
await client.mutateAndInvalidate(mutation, variables: vars, invalidateQueries: [key]);

// 2.0: objects returned by the mutation update every query automatically.
await client.mutate(mutation, variables: vars);
// For lists, either refetch them by name...
await client.mutate(mutation, variables: vars, refetchQueries: ['GetTodos']);
// ...or edit the cache with `update:` (see the README).
```

## Subscriptions

2.0 speaks `graphql-transport-ws` by default. If your server only supports the
legacy Apollo protocol:

```dart
GraphQLClient(url,
    subscriptionEndpoint: wsUrl,
    subscriptionProtocol: SubscriptionProtocol.subscriptionsTransportWs);
```

Subscriptions no longer time out after 30 seconds, stop on the server when you
cancel the stream, and reconnect automatically.

## Persistent cache

```dart
// 1.x
GraphQLClientBase(config: config.copyWith(persistCache: true));

// 2.0
GraphQLClient(url, cache: GraphQLCache(store: await PersistentStore.open()));
```

The 1.x disk cache could not be read back, so there is no data to migrate.

## Interceptors

Custom Dio interceptors still work: `GraphQLClient(url, interceptors: [...])`.
Interceptors that re-send requests should mix in `DioAwareInterceptor` and use
its `dio` getter.
