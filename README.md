# graphql_client_flutter

The simple, typed GraphQL client for Flutter.

- **One-line setup.** `GraphQLClient(url)` comes with retries, timeouts and a normalized cache.
- **Typed results without codegen.** Pass `parse: User.fromJson` and get a `User`, not a `Map`.
- **No try/catch.** Every call returns a sealed `GraphQLResult` you `switch` over.
- **Widgets that stay in sync.** `GraphQLQuery` rebuilds automatically when a mutation changes the data it shows.
- **Production features built in:** auth token refresh, subscriptions with auto-reconnect, optimistic updates, offline cache, pagination, file uploads, persisted queries.
- **Testable.** `MockTransport` lets you test your real app logic with canned responses.

```dart
final client = GraphQLClient('https://api.example.com/graphql');

final result = await client.query(
  getUser,
  variables: {'id': '1'},
  parse: (data) => User.fromJson(data['user']),
);

switch (result) {
  case GraphQLSuccess(:final data): print(data.name);
  case GraphQLFailure(:final exception): print(exception.userMessage);
}
```

---

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Queries](#queries)
- [Mutations](#mutations)
- [Subscriptions](#subscriptions)
- [Widgets](#widgets)
- [Errors](#errors)
- [Cache](#cache)
- [Authentication](#authentication)
- [Pagination](#pagination)
- [File uploads](#file-uploads)
- [Performance options](#performance-options)
- [Logging and observers](#logging-and-observers)
- [Testing](#testing)
- [Code generation](#code-generation)
- [Advanced: custom transports](#advanced-custom-transports)
- [Limitations](#limitations)
- [Migrating from 1.x](#migrating-from-1x)

## Install

```bash
flutter pub add graphql_client_flutter
```

## Quick start

**1. Create a client** (once, at startup):

```dart
final client = GraphQLClient(
  'https://api.example.com/graphql',
  subscriptionEndpoint: 'wss://api.example.com/graphql', // optional
  token: () => auth.accessToken,                          // optional
);
```

**2. Provide it to your widgets:**

```dart
runApp(GraphQLProvider(client: client, child: const MyApp()));
```

**3. Show data:**

```dart
const getUser = r'''
  query GetUser($id: ID!) {
    user(id: $id) { id name avatarUrl }
  }
''';

GraphQLQuery<User>(
  document: getUser,
  variables: {'id': userId},
  parse: (data) => User.fromJson(data['user']),
  builder: (context, state, query) => switch (state) {
    QueryLoading() => const CircularProgressIndicator(),
    QueryData(:final data) => Text(data.name),
    QueryError(:final exception) => TextButton(
        onPressed: query.refetch,
        child: Text('${exception.userMessage} Tap to retry.'),
      ),
  },
)
```

The [example app](example/main.dart) is a complete app in one file.

## Queries

```dart
final result = await client.query(
  getUser,
  variables: {'id': '1'},
  parse: (data) => User.fromJson(data['user']),
);
```

Without `parse`, `data` is the raw JSON map: `client.query<JsonMap>(getUser)`.

**Fetch policies** control the cache:

| Policy | Behaviour |
|---|---|
| `cacheFirst` (default for `query`) | Use complete cached data; otherwise fetch. |
| `cacheAndNetwork` (default for `watchQuery` and widgets) | Return cached data now and refresh it from the network. |
| `networkOnly` | Always fetch, then update the cache. |
| `cacheOnly` | Only read the cache; fail with `cacheMiss` if the data isn't there. |
| `noCache` | Always fetch; never read or write the cache. |

```dart
await client.query(getUser, fetchPolicy: FetchPolicy.networkOnly);
```

**Watch a query** to get a stream that updates whenever the cache changes:

```dart
final watch = client.watchQuery(getFeed, parse: (data) => Feed.fromJson(data['feed']));
watch.stream.listen((result) { ... });
await watch.refetch();
```

Identical queries in flight at the same time are sent only once.

## Mutations

```dart
final result = await client.mutate(
  r'mutation Like($id: ID!) { likePost(id: $id) { id likes likedByMe } }',
  variables: {'id': post.id},
);
```

Because the cache is normalized, the returned post (`id`, `likes`, `likedByMe`) updates **every** query and widget that shows it. No manual refresh.

**Optimistic UI**: show the result immediately, then roll it back automatically if the request fails:

```dart
await client.mutate(
  likePost,
  variables: {'id': post.id},
  optimisticResponse: {
    'likePost': {'__typename': 'Post', 'id': post.id, 'likes': post.likes + 1, 'likedByMe': true},
  },
);
```

**Add created items to lists** with `update`:

```dart
await client.mutate(
  createTodo,
  variables: {'title': title},
  update: (cache, data) {
    final list = cache.read(getTodos)!;
    cache.write(getTodos, {
      'todos': [...list['todos'], data['createTodo']],
    });
  },
);
```

Or simply refetch watched queries by name: `refetchQueries: ['GetTodos']`.

Mutations are never retried automatically, because a retried mutation could run twice.

## Subscriptions

```dart
client
    .subscribe(r'subscription OnMessage($room: ID!) { messageAdded(room: $room) { id text } }',
        variables: {'room': roomId},
        parse: (data) => Message.fromJson(data['messageAdded']))
    .listen((result) { ... });
```

- Uses the `graphql-transport-ws` protocol. For older servers, pass `subscriptionProtocol: SubscriptionProtocol.subscriptionsTransportWs`.
- One shared socket opens with the first subscription and closes shortly after the last one.
- If the connection drops, it reconnects with exponential backoff and restarts your subscriptions. It does not retry fatal errors such as unauthorized.
- The auth token is sent in `connection_init` and read again on every reconnect.
- Cancelling the stream subscription stops the subscription on the server.

## Widgets

| Widget | Purpose |
|---|---|
| `GraphQLProvider` | Makes a client available below it (`context.graphQLClient`). |
| `GraphQLQuery<T>` | Runs a query and rebuilds on every change. Builder gets `QueryState<T>` and a controller with `refetch()` / `fetchMore()`. |
| `GraphQLMutation<T>` | Gives the builder a `run(...)` function and a `MutationState<T>` (idle, running, success, failure). |
| `GraphQLSubscription<T>` | Subscribes while mounted; rebuilds with each event. |

```dart
GraphQLMutation<Post>(
  document: createPost,
  parse: (data) => Post.fromJson(data['createPost']),
  refetchQueries: const ['Feed'],
  onCompleted: (post) => Navigator.pop(context),
  builder: (context, state, run) => FilledButton(
    onPressed: state is MutationRunning ? null : () => run(variables: {'title': title}),
    child: const Text('Publish'),
  ),
)
```

Pull-to-refresh is one line: `RefreshIndicator(onRefresh: query.refetch, child: ...)`.

Changing `variables` loads the new result. Passing an inline `parse` closure is fine; it does not restart the query.

## Errors

Operations never throw for request failures. A failure carries a `GraphQLException` with:

- `kind`: what happened, one of `network`, `timeout`, `cancelled`, `unauthenticated`, `forbidden`, `invalidRequest`, `server`, `graphql`, `invalidResponse`, `cacheMiss` or `unknown`
- `userMessage`: short text you can show in the UI
- `errors`: the server's GraphQL errors, if any
- `statusCode`, `operationName` and `cause`: for logging

```dart
if (result case GraphQLFailure(:final exception)) {
  switch (exception.kind) {
    case GraphQLErrorKind.unauthenticated: router.go('/login');
    case GraphQLErrorKind.network: showOfflineBanner();
    default: showSnackBar(exception.userMessage);
  }
}
```

Helpers: `result.dataOrNull`, `result.dataOrThrow`, `result.map(...)`, `result.when(success: ..., failure: ...)`.

**Partial data**: by default (`ErrorPolicy.none`) any GraphQL error makes the result a failure. Use `ErrorPolicy.all` to get data and errors together, or `ErrorPolicy.ignore` to drop errors when data exists.

## Cache

Objects with `__typename` and `id` are stored once under `Type:id` (the client adds `__typename` to your queries automatically).

```dart
final client = GraphQLClient(
  url,
  cache: GraphQLCache(
    store: await PersistentStore.open(), // survives restarts, works offline
    typePolicies: {
      'Book': TypePolicy(keyFields: {'isbn': true}), // objects identified by something else
    },
  ),
);
```

**Offline cache and privacy.** `PersistentStore` writes plain JSON to the app's support directory. For sensitive data:

```dart
PersistentStore.open(
  name: 'cache_$userId',        // one file per user
  codec: myEncryptionCodec,     // Codec<String, String>, e.g. AES with a key from flutter_secure_storage
);

await client.resetStore();      // on logout: clears memory and disk before returning
```

Direct access:

```dart
client.cache.readFragment('fragment U on User { name }', idFields: {'__typename': 'User', 'id': '1'});
client.cache.writeFragment(...);
client.cache.evict('User:1');   // watching queries refetch
client.cache.gc();              // drop unreachable objects
await client.resetStore();      // e.g. after logout: clear and refetch
```

## Authentication

```dart
final client = GraphQLClient(
  url,
  token: () => storage.read('access_token'),
  refreshToken: () async {
    final tokens = await authApi.refresh();
    return tokens?.accessToken; // null = could not refresh
  },
  onRefreshFailed: (_) => auth.signOut(),
);
```

- Sends `Authorization: Bearer <token>` on every request.
- Detects expired tokens from HTTP 401 **and** from `UNAUTHENTICATED` errors in normal HTTP 200 responses (how most GraphQL servers report them).
- Concurrent requests share a single refresh. Each request is retried once with the new token.
- The token is only sent over `https://` / `wss://`, or to local and private hosts (`localhost`, `10.0.2.2`, `192.168.x.x`) for development. Pass `allowInsecureAuth: true` to override this.
- Over WebSocket, `connection_init` carries only `{'Authorization': 'Bearer <token>'}`, read again on every reconnect. HTTP `headers` are not copied to it. For a custom payload, pass `subscriptionConnectionParams: () async => {...}`.

## Pagination

```dart
GraphQLQuery<Feed>(
  document: feedQuery,
  parse: (data) => Feed.fromJson(data['feed']),
  builder: (context, state, query) => FeedList(
    feed: state.data,
    onEndReached: () => query.fetchMore(
      variables: {'after': state.data!.endCursor},
      merge: (previous, more) => {
        'feed': {
          ...more['feed'],
          'edges': [...previous['feed']['edges'], ...more['feed']['edges']],
        },
      },
    ),
  ),
)
```

## File uploads

Put a `MultipartFile` anywhere in the variables. The request is encoded following the [GraphQL multipart request spec](https://github.com/jaydenseric/graphql-multipart-request-spec):

```dart
await client.mutate(
  r'mutation Upload($file: Upload!) { uploadAvatar(file: $file) { url } }',
  variables: {'file': await MultipartFile.fromFile(path, filename: 'avatar.jpg')},
);
```

## Performance options

```dart
GraphQLClient(
  url,
  persistedQueries: true,   // Automatic Persisted Queries: send a hash instead of the query text
  useGetForQueries: true,   // GET for queries, so CDNs can cache them
  timeout: const Duration(seconds: 15),
  maxRetries: 3,            // network errors, timeouts, 429 (honours Retry-After), 5xx
);
```

Cancel a request with a `CancellationToken`:

```dart
final token = CancellationToken();
final future = client.query(search, variables: {'q': text}, cancelToken: token);
token.cancel(); // completes with GraphQLErrorKind.cancelled
```

## Logging and observers

```dart
GraphQLClient(url, logging: true); // credentials are redacted
```

For analytics or tracing, implement only the callbacks you need:

```dart
class Analytics extends GraphQLObserver {
  @override
  void onResponse(GraphQLRequest request, GraphQLResponse response, Duration elapsed) =>
      metrics.timing('graphql.${request.operationName}', elapsed);
}

GraphQLClient(url, observers: [Analytics()]);
```

## Testing

```dart
import 'package:graphql_client_flutter/testing.dart';

final mock = MockTransport()
  ..on('GetUser', variables: {'id': '1'}).reply({
    'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
  })
  ..on('CreatePost').fail(GraphQLErrorKind.network)
  ..on('OnMessage').emit([{'messageAdded': {...}}]);

final client = GraphQLClient.custom(transport: mock);

// Use `client` in GraphQLProvider for widget tests, then assert:
expect(mock.requestsFor('GetUser'), hasLength(1));
```

Replies queue up: `..reply(a)..reply(b)` answers `a`, then `b` for every later call. An unmatched operation fails with a message listing what is registered.

## Code generation

You don't need codegen. If you want fully generated types, use [graphql_codegen](https://pub.dev/packages/graphql_codegen) and pass its generated `fromJson` to `parse` (it takes the whole `data` object):

```dart
import 'package:gql/language.dart' show printNode;

final result = await client.query(
  printNode(documentNodeQueryGetUser),
  variables: Variables$Query$GetUser(id: '1').toJson(),
  parse: Query$GetUser.fromJson,
);
```

## Advanced: custom transports

`GraphQLClient` depends only on `GraphQLTransport`, so you can compose or replace the network layer:

```dart
final client = GraphQLClient.custom(
  transport: SplitTransport(
    operations: HttpTransport(url, interceptors: [MyInterceptor()]),
    subscriptions: WebSocketTransport(wsUrl, maxReconnectAttempts: 10),
  ),
);
```

Custom Dio interceptors that need to re-send requests can mix in `DioAwareInterceptor`.

## Limitations

- **Cache expiry:** the normalized cache has no per-entry expiry. Use fetch policies, `evict` or `resetStore` to control freshness.
- **Web persistence:** on the web, `PersistentStore` keeps data in memory only.
- **Not included (yet):** auto-batching of several operations into one request, and a DevTools extension.

## Migrating from 1.x

Version 2 is a redesign. See [MIGRATION.md](MIGRATION.md) for a side-by-side guide.

## License

MIT
