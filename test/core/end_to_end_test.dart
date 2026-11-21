import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

import '../support/fake_http_adapter.dart';
import '../support/fake_ws_server.dart';

void main() {
  late FakeWsServer server;

  setUp(() async => server = await FakeWsServer.start());
  tearDown(() => server.close());

  test('the one-line client routes HTTP and WebSocket with one token',
      () async {
    final adapter = FakeHttpAdapter((_, __) => ok({
          'me': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
        }));
    server.events = [
      {'ping': 'pong'},
    ];
    final client = GraphQLClient(
      'https://api.test/graphql',
      subscriptionEndpoint: server.url,
      headers: {'X-App': 'demo'},
      token: () => 'secret',
      httpClientAdapter: adapter,
    );
    addTearDown(client.dispose);

    final me = await client.query<String>(
      'query Me { me { id name } }',
      parse: (data) => (data['me'] as JsonMap)['name'] as String,
    );
    final events = await client
        .subscribe<String>('subscription Ping { ping }',
            parse: (data) => data['ping'] as String)
        .map((r) => r.dataOrThrow)
        .toList();

    expect(me.dataOrThrow, 'Ada');
    expect(adapter.requests.single.headers['Authorization'], 'Bearer secret');
    expect(adapter.requests.single.headers['X-App'], 'demo');
    expect(events, ['pong']);
    // HTTP headers stay on HTTP; the socket only gets the token.
    expect(server.initPayloads.single, {'Authorization': 'Bearer secret'});
  });

  test('resetStore clears the cache and refetches watched queries', () async {
    var name = 'Ada';
    final adapter = FakeHttpAdapter((_, __) => ok({
          'me': {'__typename': 'User', 'id': '1', 'name': name},
        }));
    final client =
        GraphQLClient('https://api.test/graphql', httpClientAdapter: adapter);
    addTearDown(client.dispose);

    final watch = client.watchQuery<JsonMap>('query Me { me { id name } }');
    final names = <Object?>[];
    final subscription = watch.stream
        .map((r) => (r.dataOrNull?['me'] as JsonMap?)?['name'])
        .listen(names.add);
    await pumpEventQueue();

    name = 'Grace';
    await client.resetStore();
    await pumpEventQueue();

    expect(names, ['Ada', 'Grace']);
    await subscription.cancel();
  });

  test('resetStore ignores results of requests started before it', () async {
    final release = Completer<void>();
    final adapter = FakeHttpAdapter((_, __) async {
      await release.future;
      return ok({
        'me': {'__typename': 'User', 'id': '1', 'name': 'Previous user'},
      });
    });
    final client =
        GraphQLClient('https://api.test/graphql', httpClientAdapter: adapter);
    addTearDown(client.dispose);

    final inFlight = client.query<JsonMap>('query Me { me { id name } }');
    await pumpEventQueue();
    final reset = client.resetStore();
    release.complete();
    await inFlight;
    await reset;

    expect(client.cache.store.keys, isEmpty);
  });

  test('persisted queries fall back when the server does not support them',
      () async {
    final adapter = FakeHttpAdapter((r, _) {
      final hashOnly = !(r.data as Map).containsKey('query');
      return hashOnly
          ? const FakeReply({
              'errors': [
                {'message': 'PersistedQueryNotSupported'},
              ],
            })
          : ok({'a': 1});
    });
    final client = GraphQLClient('https://api.test/graphql',
        httpClientAdapter: adapter, persistedQueries: true);
    addTearDown(client.dispose);

    expect((await client.query<JsonMap>('query A { a }')).isSuccess, isTrue);
    expect(
        (await client.query<JsonMap>('query B { a }',
                fetchPolicy: FetchPolicy.noCache))
            .isSuccess,
        isTrue);
    // 2 requests for the first query, then APQ is off: 1 for the second.
    expect(adapter.requests, hasLength(3));
  });

  test('GraphQLError round-trips through JSON and compares by value', () {
    const error = GraphQLError(
      message: 'boom',
      locations: [ErrorLocation(line: 1, column: 2)],
      path: ['a', 0],
      extensions: {'code': 'X'},
    );
    final copy = GraphQLError.fromJson(error.toJson());
    expect(copy, error);
    expect(copy.hashCode, error.hashCode);
    expect(error.toString(), contains('a.0'));
  });
}
