// Exercises the golden files in generated/: they must compile under this
// package's strict analysis options and behave as documented.
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.graphql.dart';

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
}
