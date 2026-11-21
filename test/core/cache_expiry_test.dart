import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = 'query GetUser { user { id name } }';

JsonMap user(String name) => {
      'user': {'__typename': 'User', 'id': '1', 'name': name},
    };

String? nameOf(GraphQLResult<JsonMap> result) =>
    (result.dataOrNull?['user'] as JsonMap?)?['name'] as String?;

void main() {
  late DateTime now;
  late MockTransport mock;
  late Store store;
  late GraphQLClient client;

  GraphQLClient newClient() => GraphQLClient.custom(
        transport: mock,
        cache: GraphQLCache(store: store, clock: () => now),
      );

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    mock = MockTransport();
    store = InMemoryStore();
    client = newClient();
  });

  Future<GraphQLResult<JsonMap>> query(
    FetchPolicy policy, {
    Duration? maxAge = const Duration(minutes: 5),
  }) =>
      client.query<JsonMap>(getUser, fetchPolicy: policy, maxAge: maxAge);

  test('cacheFirst uses fresh data and refetches stale data', () async {
    mock.on('GetUser')
      ..reply(user('Ada'))
      ..reply(user('Ada (fresh)'));

    await query(FetchPolicy.cacheFirst);
    now = now.add(const Duration(minutes: 4));
    final fresh = await query(FetchPolicy.cacheFirst);
    expect((fresh as GraphQLSuccess).source, ResultSource.cache);
    expect(mock.requests, hasLength(1));

    now = now.add(const Duration(minutes: 2));
    final refetched = await query(FetchPolicy.cacheFirst);
    expect(nameOf(refetched), 'Ada (fresh)');
    expect(mock.requests, hasLength(2));
  });

  test('stale data is returned when the server is unreachable', () async {
    mock.on('GetUser')
      ..reply(user('Ada'))
      ..fail(GraphQLErrorKind.network);

    await query(FetchPolicy.cacheFirst);
    now = now.add(const Duration(hours: 1));
    final result = await query(FetchPolicy.cacheFirst);

    expect(nameOf(result), 'Ada');
    expect((result as GraphQLSuccess).source, ResultSource.cache);
  });

  test('stale data is not used to hide non-transient errors', () async {
    mock.on('GetUser')
      ..reply(user('Ada'))
      ..replyErrors(['forbidden'], code: 'FORBIDDEN');

    await query(FetchPolicy.cacheFirst);
    now = now.add(const Duration(hours: 1));
    final result = await query(FetchPolicy.cacheFirst);

    expect(result.exceptionOrNull?.kind, GraphQLErrorKind.forbidden);
  });

  test('cacheAndNetwork skips the refresh while data is fresh', () async {
    mock.on('GetUser').reply(user('Ada'));
    await query(FetchPolicy.networkOnly);

    await query(FetchPolicy.cacheAndNetwork);
    await pumpEventQueue();
    expect(mock.requests, hasLength(1));

    now = now.add(const Duration(minutes: 10));
    await query(FetchPolicy.cacheAndNetwork);
    await pumpEventQueue();
    expect(mock.requests, hasLength(2));
  });

  test('without maxAge, cached data never goes stale', () async {
    mock.on('GetUser').reply(user('Ada'));
    await query(FetchPolicy.cacheFirst, maxAge: null);
    now = now.add(const Duration(days: 365));
    await query(FetchPolicy.cacheFirst, maxAge: null);
    expect(mock.requests, hasLength(1));
  });

  test('defaultMaxAge applies when a query passes none', () async {
    client = GraphQLClient.custom(
      transport: mock,
      cache: GraphQLCache(store: store, clock: () => now),
      defaultMaxAge: const Duration(seconds: 30),
    );
    mock.on('GetUser').reply(user('Ada'));

    await client.query(getUser);
    now = now.add(const Duration(minutes: 1));
    await client.query(getUser);

    expect(mock.requests, hasLength(2));
  });

  test('write times live in the store, so they survive a restart', () async {
    mock.on('GetUser').reply(user('Ada'));
    await query(FetchPolicy.networkOnly);

    client = newClient(); // Same store, new cache: like reopening the app.
    final request = GraphQLRequest(document: GraphQLDocument.parse(getUser));
    expect(client.cache.writtenAt(request), now);

    client.cache.gc();
    expect(client.cache.writtenAt(request), now, reason: 'gc keeps them');
  });

  test('watchQuery with fresh data emits once and skips the network', () async {
    mock.on('GetUser').reply(user('Ada'));
    await query(FetchPolicy.networkOnly);

    final watch =
        client.watchQuery<JsonMap>(getUser, maxAge: const Duration(minutes: 5));
    final results = <GraphQLResult<JsonMap>>[];
    final subscription = watch.stream.listen(results.add);
    await pumpEventQueue();

    expect(results, hasLength(1));
    expect(mock.requests, hasLength(1));
    await subscription.cancel();
  });
}
