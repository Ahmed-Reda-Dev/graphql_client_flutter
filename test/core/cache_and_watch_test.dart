// Calls without a type argument mirror apps that do not use strict inference.
// ignore_for_file: inference_failure_on_function_invocation

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = r'query GetUser($id: ID!) { user(id: $id) { id name } }';
const listUsers = 'query Users { users { id name } }';
const renameUser = r'''
  mutation Rename($id: ID!, $name: String!) {
    renameUser(id: $id, name: $name) { id name }
  }
''';
const addUser = r'''
  mutation AddUser($name: String!) { addUser(name: $name) { id name } }
''';

JsonMap userJson(String id, String name) =>
    {'__typename': 'User', 'id': id, 'name': name};

String? nameOf(GraphQLResult<JsonMap>? result) =>
    ((result?.dataOrNull?['user']) as JsonMap?)?['name'] as String?;

List<String> namesIn(GraphQLResult<JsonMap>? result) =>
    ((result?.dataOrNull?['users'] as List?) ?? const [])
        .map((u) => (u as JsonMap)['name'] as String)
        .toList();

void main() {
  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport();
    client = GraphQLClient.custom(transport: mock);
  });

  tearDown(() => client.dispose());

  group('normalized cache', () {
    test('a mutation result updates every query showing the object', () async {
      mock
        ..on('GetUser').reply({'user': userJson('1', 'Ada')})
        ..on('Users').reply({
          'users': [userJson('1', 'Ada'), userJson('2', 'Alan')],
        })
        ..on('Rename').reply({'renameUser': userJson('1', 'Ada L.')});

      await client.query(getUser, variables: {'id': '1'});
      await client.query(listUsers);
      await client.mutate(renameUser, variables: {'id': '1', 'name': 'Ada L.'});

      final single = await client.query<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheOnly);
      final list = await client.query<JsonMap>(listUsers,
          fetchPolicy: FetchPolicy.cacheOnly);
      expect(nameOf(single), 'Ada L.');
      expect(namesIn(list), ['Ada L.', 'Alan']);
    });

    test('custom key fields through TypePolicy', () async {
      client = GraphQLClient.custom(
        transport: mock,
        cache: GraphQLCache(typePolicies: {
          'Book': const TypePolicy(keyFields: {'isbn': true}),
        }),
      );
      mock.on('Book').reply({
        'book': {'__typename': 'Book', 'isbn': '978', 'title': 'Dune'},
      });
      await client.query('query Book { book { isbn title } }');
      expect(client.cache.store.keys, contains('Book:{"isbn":"978"}'));
    });

    test('evict removes an object; gc removes unreachable ones', () async {
      mock.on('GetUser').reply({'user': userJson('1', 'Ada')});
      await client.query(getUser, variables: {'id': '1'});

      client.cache.store.put('User:orphan', userJson('orphan', 'X'));
      client.cache.gc();
      expect(client.cache.store.keys, isNot(contains('User:orphan')));

      client.cache.evict('User:1');
      final cached = await client.query(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheOnly);
      expect(cached.exceptionOrNull?.kind, GraphQLErrorKind.cacheMiss);
    });

    test('identify and fragments', () {
      final cache = GraphQLCache();
      expect(cache.identify(userJson('7', 'Grace')), 'User:7');

      cache.writeFragment(
        'fragment U on User { id name }',
        idFields: {'__typename': 'User', 'id': '7'},
        data: userJson('7', 'Grace'),
      );
      expect(
        cache.readFragment('fragment U on User { name }',
            idFields: {'__typename': 'User', 'id': '7'})?['name'],
        'Grace',
      );
    });
  });

  group('mutations', () {
    test('optimistic data shows immediately and is rolled back on failure',
        () async {
      mock = MockTransport(latency: const Duration(milliseconds: 30));
      client = GraphQLClient.custom(transport: mock);
      mock
        ..on('GetUser').reply({'user': userJson('1', 'Ada')})
        ..on('Rename').fail(GraphQLErrorKind.network);
      await client.query(getUser, variables: {'id': '1'});

      final future = client.mutate(
        renameUser,
        variables: {'id': '1', 'name': 'Optimistic'},
        optimisticResponse: {'renameUser': userJson('1', 'Optimistic')},
      );
      await pumpEventQueue();
      final during = await client.query<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheOnly);
      expect(nameOf(during), 'Optimistic');
      expect((during as GraphQLSuccess).source, ResultSource.optimistic);

      expect((await future).isSuccess, isFalse);
      final after = await client.query<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheOnly);
      expect(nameOf(after), 'Ada');
    });

    test('concurrent optimistic layers roll back independently', () async {
      const setName = r'mutation SetName($v: String) { u(v: $v) { id name } }';
      const setAge = r'mutation SetAge($v: Int) { u(v: $v) { id age } }';
      const read = 'query U { u { id name age } }';
      mock = MockTransport(latency: const Duration(milliseconds: 20));
      client = GraphQLClient.custom(transport: mock);
      mock
        ..on('U').reply({
          'u': {'__typename': 'U', 'id': '1', 'name': 'a', 'age': 1},
        })
        ..on('SetName').fail(GraphQLErrorKind.network)
        ..on('SetAge').reply({
          'u': {'__typename': 'U', 'id': '1', 'age': 2},
        });
      await client.query(read);

      final name = client.mutate(setName, optimisticResponse: {
        'u': {'__typename': 'U', 'id': '1', 'name': 'B'},
      });
      final age = client.mutate(setAge, optimisticResponse: {
        'u': {'__typename': 'U', 'id': '1', 'age': 2},
      });
      await Future.wait([name, age]);

      final u = (await client.query<JsonMap>(read,
              fetchPolicy: FetchPolicy.cacheOnly))
          .dataOrThrow['u'] as JsonMap;
      expect(u['name'], 'a', reason: 'the failed mutation is rolled back');
      expect(u['age'], 2);
    });

    test('a throwing update callback does not fail a successful mutation',
        () async {
      mock.on('AddUser').reply({'addUser': userJson('2', 'Alan')});
      final errors = <Object>[];

      final result = await runZonedGuarded(
        () => client.mutate(addUser,
            variables: {'name': 'Alan'},
            update: (_, __) => throw StateError('bug in update')),
        (error, _) => errors.add(error),
      );

      expect(result?.isSuccess, isTrue);
      expect(errors.single, isA<StateError>());
    });

    test('update adds a created object to a cached list', () async {
      mock
        ..on('Users').reply({
          'users': [userJson('1', 'Ada')]
        })
        ..on('AddUser').reply({'addUser': userJson('2', 'Alan')});
      await client.query(listUsers);

      await client.mutate(
        addUser,
        variables: {'name': 'Alan'},
        update: (cache, data) {
          final current = cache.read(listUsers)!;
          cache.write(listUsers, {
            'users': [...current['users'] as List, data['addUser']],
          });
        },
      );

      final list = await client.query<JsonMap>(listUsers,
          fetchPolicy: FetchPolicy.cacheOnly);
      expect(namesIn(list), ['Ada', 'Alan']);
    });

    test('refetchQueries refetches watched queries by name', () async {
      mock
        ..on('Users').reply({
          'users': [userJson('1', 'Ada')]
        })
        ..on('AddUser').reply({'addUser': userJson('2', 'Alan')});
      final watch = client.watchQuery<JsonMap>(listUsers,
          fetchPolicy: FetchPolicy.networkOnly);
      final subscription = watch.stream.listen((_) {});
      await pumpEventQueue();

      await client.mutate(addUser,
          variables: {'name': 'Alan'}, refetchQueries: ['Users']);

      expect(mock.requestsFor('Users'), hasLength(2));
      await subscription.cancel();
    });
  });

  group('watchQuery', () {
    test('emits cache then network for cacheAndNetwork', () async {
      mock.on('GetUser')
        ..reply({'user': userJson('1', 'Ada')})
        ..reply({'user': userJson('1', 'Ada (fresh)')});
      await client.query(getUser, variables: {'id': '1'});

      final watch = client.watchQuery<JsonMap>(getUser, variables: {'id': '1'});
      final results = <GraphQLResult<JsonMap>>[];
      final subscription = watch.stream.listen(results.add);
      await pumpEventQueue();

      expect(results.map(nameOf), ['Ada', 'Ada (fresh)']);
      expect((results.first as GraphQLSuccess).source, ResultSource.cache);
      await subscription.cancel();
    });

    test('re-emits when another operation changes the cache', () async {
      mock
        ..on('GetUser').reply({'user': userJson('1', 'Ada')})
        ..on('Rename').reply({'renameUser': userJson('1', 'Countess')});
      final watch = client.watchQuery<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheFirst);
      final names = <String?>[];
      final subscription = watch.stream.map(nameOf).listen(names.add);
      await pumpEventQueue();

      await client
          .mutate(renameUser, variables: {'id': '1', 'name': 'Countess'});
      await pumpEventQueue();

      expect(names, ['Ada', 'Countess']);
      await subscription.cancel();
    });

    test('does not re-emit identical data', () async {
      mock.on('GetUser').reply({'user': userJson('1', 'Ada')});
      final watch = client.watchQuery<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly);
      final results = <GraphQLResult<JsonMap>>[];
      final subscription = watch.stream.listen(results.add);
      await pumpEventQueue();
      await watch.refetch();
      await pumpEventQueue();

      // The refetch returned identical data: no rebuild-triggering emission.
      expect(results, hasLength(1));
      await subscription.cancel();
    });

    test('fetchMore merges pages and updates the cache', () async {
      const feed =
          r'query Feed($after: String) { users(after: $after) { id name } }';
      mock
        ..on('Feed', variables: {}).reply({
          'users': [userJson('1', 'Ada')]
        })
        ..on('Feed', variables: {'after': '1'}).reply({
          'users': [userJson('2', 'Alan')]
        });
      final watch = client.watchQuery<JsonMap>(feed,
          fetchPolicy: FetchPolicy.networkOnly);
      final subscription = watch.stream.listen((_) {});
      await pumpEventQueue();

      final merged = await watch.fetchMore(
        variables: {'after': '1'},
        merge: (previous, more) => {
          'users': [...previous['users'] as List, ...more['users'] as List],
        },
      );

      expect(namesIn(merged), ['Ada', 'Alan']);
      expect(namesIn(watch.latest), ['Ada', 'Alan']);
      await subscription.cancel();
    });

    test('fetchMore called twice while loading merges the page once', () async {
      const feed =
          r'query Feed($after: String) { users(after: $after) { id name } }';
      mock = MockTransport(latency: const Duration(milliseconds: 10));
      client = GraphQLClient.custom(transport: mock);
      mock
        ..on('Feed', variables: {}).reply({
          'users': [userJson('1', 'Ada')]
        })
        ..on('Feed', variables: {'after': '1'}).reply({
          'users': [userJson('2', 'Alan')]
        });
      final watch = client.watchQuery<JsonMap>(feed,
          fetchPolicy: FetchPolicy.networkOnly);
      final subscription = watch.stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));

      JsonMap merge(JsonMap previous, JsonMap more) => {
            'users': [...previous['users'] as List, ...more['users'] as List],
          };
      await Future.wait([
        watch.fetchMore(variables: {'after': '1'}, merge: merge),
        watch.fetchMore(variables: {'after': '1'}, merge: merge),
      ]);

      expect(namesIn(watch.latest), ['Ada', 'Alan']);
      await subscription.cancel();
    });

    test('fetchMore before the first result fails instead of throwing',
        () async {
      final watch = client.watchQuery<JsonMap>(getUser);
      final result = await watch.fetchMore(
          merge: (previous, more) => throw StateError('x'));
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.invalidRequest);
    });

    test('a merge that throws becomes a failure', () async {
      mock.on('GetUser').reply({'user': userJson('1', 'Ada')});
      final watch = client.watchQuery<JsonMap>(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly);
      final subscription = watch.stream.listen((_) {});
      await pumpEventQueue();

      final result = await watch.fetchMore(
          merge: (previous, more) => throw StateError('x'));

      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.unknown);
      await subscription.cancel();
    });

    test('setVariables loads the new result', () async {
      mock
        ..on('GetUser', variables: {'id': '1'})
            .reply({'user': userJson('1', 'Ada')})
        ..on('GetUser', variables: {'id': '2'})
            .reply({'user': userJson('2', 'Alan')});
      final watch = client.watchQuery<JsonMap>(getUser, variables: {'id': '1'});
      final names = <String?>[];
      final subscription = watch.stream.map(nameOf).listen(names.add);
      await pumpEventQueue();

      await watch.setVariables({'id': '2'});
      await pumpEventQueue();

      expect(names.last, 'Alan');
      await subscription.cancel();
    });

    test('polling refetches on an interval', () async {
      mock.on('GetUser').reply({'user': userJson('1', 'Ada')});
      final watch = client.watchQuery<JsonMap>(getUser,
          variables: {'id': '1'},
          fetchPolicy: FetchPolicy.networkOnly,
          pollInterval: const Duration(milliseconds: 20));
      final subscription = watch.stream.listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 75));
      await subscription.cancel();

      expect(mock.requests.length, greaterThanOrEqualTo(3));
    });

    test('stops when the last listener cancels', () async {
      mock.on('GetUser').reply({'user': userJson('1', 'Ada')});
      final watch = client.watchQuery<JsonMap>(getUser, variables: {'id': '1'});
      final subscription = watch.stream.listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();

      await client.refetchQueries(['GetUser']);
      expect(mock.requests, hasLength(1));
    });
  });
}
