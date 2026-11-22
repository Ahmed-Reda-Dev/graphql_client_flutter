// Exercises the golden files in generated/: they must compile under this
// package's strict analysis options and behave as documented.
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.graphql.dart';
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
}
