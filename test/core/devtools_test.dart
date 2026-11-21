import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/src/core/devtools/devtools_bridge.dart';
import 'package:graphql_client_flutter/testing.dart';

void main() {
  final bridge = DevToolsBridge.instance;

  setUp(() => bridge.handle('clearOperations', const {}));

  List<JsonMap> operations() =>
      (bridge.handle('getOperations', const {})['operations'] as List)
          .cast<JsonMap>();

  test('clients register with DevTools in debug builds', () async {
    final client = GraphQLClient.custom(transport: MockTransport());
    final clients = bridge.handle('getClients', const {})['clients'] as List;
    expect(clients, isNotEmpty);

    await client.dispose();
    final after = bridge.handle('getClients', const {})['clients'] as List;
    expect(after.length, clients.length - 1);
  });

  test('operations are recorded with their outcome', () async {
    final mock = MockTransport()
      ..on('GetUser').reply({
        'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
      })
      ..on('Broken').fail(GraphQLErrorKind.timeout);
    final client = GraphQLClient.custom(transport: mock);
    addTearDown(client.dispose);

    await client.query<JsonMap>('query GetUser { user { id name } }');
    await client.query<JsonMap>('query GetUser { user { id name } }');
    await client.query<JsonMap>('query Broken { x }');

    final statuses = [
      for (final op in operations()) '${op['operationName']}:${op['status']}',
    ];
    expect(statuses, [
      'GetUser:pending',
      'GetUser:success',
      'GetUser:cache',
      'Broken:pending',
      'Broken:failure',
    ]);
    final success = operations()[1];
    expect(success['durationMs'], isA<int>());
    expect((success['data'] as JsonMap)['user'], isNotNull);
    expect(operations().last['errorKind'], 'timeout');
  });

  test('the cache can be inspected and cleared', () async {
    final mock = MockTransport()
      ..on('GetUser').reply({
        'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
      });
    final client = GraphQLClient.custom(transport: mock);
    addTearDown(client.dispose);
    await client.query<JsonMap>('query GetUser { user { id name } }');

    final clients = bridge.handle('getClients', const {})['clients'] as List;
    final id = '${(clients.last as JsonMap)['id']}';
    final entities =
        bridge.handle('getCache', {'clientId': id})['entities'] as JsonMap;
    expect(
        entities['User:1'], {'__typename': 'User', 'id': '1', 'name': 'Ada'});
    expect(client.cache.store.keys, contains(r'$writeTimes'));
    expect(entities.keys, isNot(contains(r'$writeTimes')),
        reason: 'internal bookkeeping is hidden from DevTools');

    bridge.handle('clearCache', {'clientId': id});
    expect(client.cache.store.keys, isEmpty);
  });

  test('unknown methods are rejected', () {
    expect(() => bridge.handle('nope', const {}), throwsArgumentError);
  });
}
