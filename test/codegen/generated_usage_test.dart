// Exercises the golden files in generated/: they must compile under this
// package's strict analysis options and behave as documented.
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

import 'generated/schema.graphql.dart';
import 'generated/search.graphql.dart';
import 'generated/user.graphql.dart';

void main() {
  group('generated enums', () {
    test('map schema names both ways', () {
      expect(Role.fromJson('SUPER_USER'), Role.superUser);
      expect(Role.superUser.toJson(), 'SUPER_USER');
    });

    test('an unknown value does not break the app', () {
      expect(Role.fromJson('OWNER'), Role.$unknown);
      expect(() => Role.$unknown.toJson(), throwsStateError);
    });
  });

  group('generated inputs', () {
    test('leave unset optional fields out', () {
      expect(const CreateUserInput(name: 'Ada').toJson(), {'name': 'Ada'});
    });

    test('convert nested inputs, enums, lists and dates', () {
      final input = CreateUserInput(
        name: 'Ada',
        role: Role.admin,
        tags: ['math'],
        birthday: DateTime.utc(1815, 12, 10),
        filter: const UserFilter(nameContains: 'A'),
      );
      expect(input.toJson(), {
        'name': 'Ada',
        'role': 'ADMIN',
        'tags': ['math'],
        'birthday': '1815-12-10T00:00:00.000Z',
        'filter': {'nameContains': 'A'},
      });
    });
  });

  group('generated data classes', () {
    final json = {
      'user': {
        '__typename': 'User',
        'id': '1',
        'name': 'Ada',
        'role': 'ADMIN',
        'createdAt': '2026-01-02T03:04:05.000Z',
        'avatar': {'__typename': 'Image', 'url': 'a.png', 'width': 64},
        'tags': ['math'],
        'scores': [1, null, 2.5],
        'metadata': {'any': 'json'},
        'best': null,
      },
    };

    test('read a response into typed fields', () {
      final user = GetUserData.fromJson(json).user!;

      expect(user.name, 'Ada');
      expect(user.email, isNull); // @include dropped it.
      expect(user.role, Role.admin);
      expect(user.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(user.avatar?.width, 64);
      expect(user.scores, [1.0, null, 2.5]);
      expect(user.metadata, {'any': 'json'});
      expect(user.best, isNull);
    });

    test('write back the same JSON, ready for the cache', () {
      expect(GetUserData.fromJson(json).toJson(), {
        '__typename': 'Query',
        'user': {
          ...json['user']!,
          'email': null,
          'scores': [1.0, null, 2.5]
        },
      });
    });
  });

  group('generated sealed classes', () {
    String describe(SearchData$Search result) => switch (result) {
          SearchData$Search$User(:final name) => 'user $name',
          SearchData$Search$Post(:final title) => 'post $title',
          SearchData$Search$Unknown(:final typename) => 'other $typename',
        };

    test('pick the variant from __typename, exhaustively', () {
      final data = SearchData.fromJson({
        'search': [
          {'__typename': 'User', 'id': '1', 'name': 'Ada', 'avatar': null},
          {'__typename': 'Post', 'id': '2', 'title': 'Notes'},
          {'__typename': 'Comment'},
        ],
      });
      expect(data.search.map(describe),
          ['user Ada', 'post Notes', 'other Comment']);
    });

    test('shared fields are available without a switch', () {
      final data = EntriesData.fromJson({
        'entries': [
          {
            '__typename': 'Post',
            'id': '1',
            'owner': {'__typename': 'User', 'name': 'Ada'},
            'title': 'Notes',
          },
          {
            '__typename': 'Comment',
            'id': '2',
            'owner': {'__typename': 'User', 'name': 'Alan'},
          },
        ],
      });
      expect(data.entries.map((e) => e.owner.name), ['Ada', 'Alan']);
    });

    test('a type added later keeps its __typename in toJson', () {
      final json = {'__typename': 'Comment', 'id': '9'};
      expect(AnyNodeData.fromJson({'node': json}).node?.toJson(), json);
    });
  });

  group('generated client extensions', () {
    late MockTransport mock;
    late GraphQLClient client;

    JsonMap userJson(String name) => {
          '__typename': 'User',
          'id': '1',
          'name': name,
          'role': 'ADMIN',
          'createdAt': '2026-01-02T03:04:05.000Z',
          'avatar': null,
          'tags': <String>[],
          'scores': null,
          'metadata': null,
          'best': null,
        };

    setUp(() {
      mock = MockTransport();
      client = GraphQLClient.custom(transport: mock);
    });

    tearDown(() => client.dispose());

    test('queries take typed variables and return typed data', () async {
      mock.on('GetUser').reply({'user': userJson('Ada')});

      final result = await client.getUser(id: '1');

      expect(result.dataOrNull?.user?.name, 'Ada');
      expect(mock.requests.single.variables, {'id': '1'});
    });

    test('optional variables are left out until set', () async {
      mock.on('GetUser').reply({'user': userJson('Ada')});
      await client.getUser(id: '1', withEmail: true);
      expect(mock.requests.single.variables, {'id': '1', 'withEmail': true});
    });

    test('watch keeps typed data in sync with the cache', () async {
      mock
        ..on('GetUser').reply({'user': userJson('Ada')})
        ..on('RenameUser').reply({
          'renameUser': {'__typename': 'User', 'id': '1', 'name': 'Ada L.'},
        });
      final names = <String?>[];
      final subscription = client
          .watchGetUser(id: '1')
          .stream
          .listen((r) => names.add(r.dataOrNull?.user?.name));
      await pumpEventQueue();

      await client.renameUser(id: '1', name: 'Ada L.');
      await pumpEventQueue();

      expect(names.last, 'Ada L.');
      await subscription.cancel();
    });

    test('mutations take a typed optimistic response and update', () async {
      mock.on('CreateUser').reply({
        'createUser': {
          '__typename': 'User',
          'id': '2',
          'name': 'Grace',
          'role': 'GUEST',
        },
      });
      CreateUserData? updated;

      final result = await client.createUser(
        input: const CreateUserInput(name: 'Grace'),
        optimisticResponse: const CreateUserData(
          createUser: CreateUserData$CreateUser(
            id: 'temp',
            name: 'Grace',
            role: Role.guest,
          ),
        ),
        update: (cache, data) => updated = data,
      );

      expect(result.dataOrNull?.createUser.id, '2');
      expect(updated?.createUser.role, Role.guest);
      expect(mock.requests.single.variables, {
        'input': {'name': 'Grace'},
      });
    });

    test('subscriptions stream typed data', () async {
      mock.on('OnUserAdded').emit([
        {
          'userAdded': {'__typename': 'User', 'id': '3', 'name': 'Alan'},
        },
      ]);

      final names = await client
          .onUserAdded()
          .map((r) => r.dataOrNull?.userAdded.name)
          .toList();

      expect(names, ['Alan']);
    });
  });
}
