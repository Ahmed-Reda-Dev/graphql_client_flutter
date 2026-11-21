@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';
import 'package:web/web.dart' as web;

void main() {
  setUp(() => web.window.localStorage.clear());

  Future<PersistentStore> open([String name = 'test_cache']) =>
      PersistentStore.open(name: name, writeDelay: Duration.zero);

  test('cached query results survive a reload (localStorage)', () async {
    final mock = MockTransport()
      ..on('GetUser').reply({
        'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
      });
    const getUser = 'query GetUser { user { id name } }';

    final first = GraphQLClient.custom(
      transport: mock,
      cache: GraphQLCache(store: await open()),
    );
    await first.query<JsonMap>(getUser);
    await first.dispose();

    final reloaded = GraphQLClient.custom(
      transport: MockTransport(), // Any network use would fail.
      cache: GraphQLCache(store: await open()),
    );
    final result = await reloaded.query<JsonMap>(getUser,
        fetchPolicy: FetchPolicy.cacheOnly);

    expect((result.dataOrThrow['user'] as JsonMap)['name'], 'Ada');
  });

  test('stores are isolated by name', () async {
    final a = await open('user_a')
      ..put('User:1', {'name': 'A'});
    await a.flush();

    final b = await open('user_b');
    expect(b.get('User:1'), isNull);
  });

  test('corrupt data starts an empty store', () async {
    web.window.localStorage
        .setItem('graphql_client_flutter.test_cache', '{not json');
    final store = await open();
    expect(store.keys, isEmpty);
  });

  test('clear removes the data from localStorage', () async {
    final store = await open()
      ..put('User:1', {'name': 'A'});
    await store.flush();
    store.clear();
    await store.flush();

    expect(
      web.window.localStorage.getItem('graphql_client_flutter.test_cache'),
      '{}',
    );
  });
}
