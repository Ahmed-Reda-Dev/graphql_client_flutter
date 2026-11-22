import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = r'query GetUser($id: ID!) { user(id: $id) { id name } }';

GraphQLRequest userRequest(String id) => GraphQLRequest(
      document: GraphQLDocument.parse(getUser),
      variables: {'id': id},
    );

JsonMap userData(String id) => {
      'user': {'__typename': 'User', 'id': id, 'name': 'User $id'},
    };

void main() {
  late GraphQLCache cache;

  void writeUser(String id) => cache.writeQuery(userRequest(id), userData(id));

  JsonMap? readUser(String id) => cache.readQuery(userRequest(id));

  setUp(() => cache = GraphQLCache(maxEntities: 2));

  test('evicts the least recently written entity past the limit', () {
    writeUser('1');
    writeUser('2');
    writeUser('3');

    expect(cache.store.get('User:1'), isNull);
    expect(cache.store.get('User:2'), isNotNull);
    expect(cache.store.get('User:3'), isNotNull);
  });

  test('reads count as use', () {
    writeUser('1');
    writeUser('2');
    readUser('1'); // User:2 is now the least recently used.
    writeUser('3');

    expect(cache.store.get('User:1'), isNotNull);
    expect(cache.store.get('User:2'), isNull);
  });

  test('never evicts root operation types or bookkeeping entries', () {
    for (var i = 0; i < 5; i++) {
      writeUser('$i');
    }

    expect(cache.store.get('Query'), isNotNull);
    expect(cache.store.get(r'$writeTimes'), isNotNull);
    expect(
      cache.store.keys.where((id) => id.startsWith('User:')),
      hasLength(2),
    );
  });

  test('a result whose entity was evicted becomes a cache miss', () async {
    final mock = MockTransport();
    mock.on('GetUser').respond(
        (r) => GraphQLResponse(data: userData(r.variables['id'] as String)));
    final client = GraphQLClient.custom(transport: mock, cache: cache);

    for (final id in ['1', '2', '3']) {
      await client.query<JsonMap>(getUser, variables: {'id': id});
    }
    expect(readUser('1'), isNull);

    await client.query<JsonMap>(getUser, variables: {'id': '1'});
    expect(mock.requests, hasLength(4)); // Fetched again, not served stale.
  });

  test('applies to entities already in the store, oldest first', () {
    cache = GraphQLCache(
      maxEntities: 2,
      store: InMemoryStore({
        'User:a': {'__typename': 'User', 'id': 'a'},
        'User:b': {'__typename': 'User', 'id': 'b'},
      }),
    );
    writeUser('1');

    expect(cache.store.get('User:a'), isNull);
    expect(cache.store.get('User:b'), isNotNull);
  });

  test('evict and clear keep the limit consistent', () {
    writeUser('1');
    writeUser('2');
    cache.evict('User:1');
    writeUser('3'); // Room was freed: nothing else is evicted.
    expect(cache.store.get('User:2'), isNotNull);

    cache.clear();
    writeUser('4');
    writeUser('5');
    expect(cache.store.get('User:4'), isNotNull);
    expect(cache.store.get('User:5'), isNotNull);
  });

  test('no limit by default', () {
    cache = GraphQLCache();
    for (var i = 0; i < 50; i++) {
      writeUser('$i');
    }
    expect(
        cache.store.keys.where((id) => id.startsWith('User:')), hasLength(50));
  });
}
