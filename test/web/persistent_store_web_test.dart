@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';
import 'package:web/web.dart' as web;

void main() {
  // Each test gets its own store, so IndexedDB data never leaks between
  // tests (the database stays open for the whole run).
  var counter = 0;
  late String name;

  setUp(() {
    name = 'web_test_${DateTime.now().microsecondsSinceEpoch}_${counter++}';
    web.window.localStorage.clear();
  });

  Future<PersistentStore> open([String? storeName]) =>
      PersistentStore.open(name: storeName ?? name, writeDelay: Duration.zero);

  test('cached query results survive a reload', () async {
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

  test('data is kept in IndexedDB, not localStorage', () async {
    final store = await open()
      ..put('User:1', {'name': 'A'});
    await store.flush();

    expect(web.window.localStorage.length, 0);
    expect((await open()).get('User:1'), {'name': 'A'});
  });

  test('holds more than localStorage allows (about 5 MB)', () async {
    final store = await open();
    final big = 'x' * (1024 * 1024); // 1 MB per entity, 7 MB in all.
    for (var i = 0; i < 7; i++) {
      store.put('Blob:$i', {'data': big});
    }
    await store.flush();

    expect((await open()).keys, hasLength(7));
  });

  test('moves data saved by earlier versions out of localStorage', () async {
    web.window.localStorage.setItem(
      'graphql_client_flutter.$name',
      '{"User:1":{"name":"Legacy"}}',
    );

    final store = await open();

    expect(store.get('User:1'), {'name': 'Legacy'});
    expect(web.window.localStorage.getItem('graphql_client_flutter.$name'),
        isNull);
    expect((await open()).get('User:1'), {'name': 'Legacy'});
  });

  test('stores are isolated by name', () async {
    final a = await open('${name}_a')
      ..put('User:1', {'name': 'A'});
    await a.flush();

    final b = await open('${name}_b');
    expect(b.get('User:1'), isNull);
  });

  test('corrupt data starts an empty store', () async {
    web.window.localStorage
        .setItem('graphql_client_flutter.$name', '{not json');
    final store = await open();
    expect(store.keys, isEmpty);
    expect((await open()).keys, isEmpty);
  });

  test('clear removes the saved data', () async {
    final store = await open()
      ..put('User:1', {'name': 'A'});
    await store.flush();
    store.clear();
    await store.flush();

    expect((await open()).keys, isEmpty);
  });

  test('falls back to localStorage when IndexedDB is unavailable', () async {
    // Like a browser that blocks IndexedDB (some private modes and
    // sandboxed iframes): reading it throws.
    JSAny? blocked() => throw StateError('blocked');
    final descriptor = JSObject()
      ..['configurable'] = true.toJS
      ..['get'] = blocked.toJS;
    (globalContext['Object']! as JSObject).callMethod<JSAny?>(
      'defineProperty'.toJS,
      web.window,
      'indexedDB'.toJS,
      descriptor,
    );
    addTearDown(() => web.window.delete('indexedDB'.toJS));

    final store = await open('${name}_fallback')
      ..put('User:1', {'name': 'A'});
    await store.flush();

    expect(
      web.window.localStorage
          .getItem('graphql_client_flutter.${name}_fallback'),
      contains('User:1'),
    );
  });
}
