import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

void main() {
  group('GraphQLDocument', () {
    test('accepts shorthand queries the old regex validator rejected', () {
      final document = GraphQLDocument.parse('{ user { name } }');
      expect(document.type, GraphQLOperationType.query);
      expect(document.operationName, isNull);
    });

    test('adds __typename to nested selection sets', () {
      final document = GraphQLDocument.parse('query Q { user { name } }');
      expect(document.printed, matches(RegExp(r'user \{\s+__typename')));
    });

    test('can leave the document untouched', () {
      final document = GraphQLDocument.parse('query Q { user { name } }',
          addTypename: false);
      expect(document.printed, isNot(contains('__typename')));
    });

    test('selects an operation by name and requires one when ambiguous', () {
      const source = 'query A { a } mutation B { b }';
      expect(GraphQLDocument.parse(source, operationName: 'B').type,
          GraphQLOperationType.mutation);
      expect(
        () => GraphQLDocument.parse(source),
        throwsA(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.invalidRequest)
            .having((e) => e.message, 'message', contains('A, B'))),
      );
    });

    test('reports syntax errors as invalidRequest', () {
      expect(
        () => GraphQLDocument.parse('query { user { name }'),
        throwsA(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.invalidRequest)),
      );
    });

    test('caches parsed documents', () {
      expect(
        identical(GraphQLDocument.parse('{ cached }'),
            GraphQLDocument.parse('{ cached }')),
        isTrue,
      );
    });

    test('computes a stable sha256 for persisted queries', () {
      final hash = GraphQLDocument.parse('{ a }').sha256Hash;
      expect(hash, hasLength(64));
      expect(GraphQLDocument.parse('{ a }').sha256Hash, hash);
    });
  });

  group('GraphQLException.kindFor', () {
    GraphQLError withCode(String code) =>
        GraphQLError(message: code, extensions: {'code': code});

    test('error codes win over the HTTP status', () {
      expect(
        GraphQLException.kindFor(
            statusCode: 200, errors: [withCode('UNAUTHENTICATED')]),
        GraphQLErrorKind.unauthenticated,
      );
      expect(
        GraphQLException.kindFor(errors: [withCode('BAD_USER_INPUT')]),
        GraphQLErrorKind.invalidRequest,
      );
    });

    test('falls back to the HTTP status', () {
      expect(GraphQLException.kindFor(statusCode: 401),
          GraphQLErrorKind.unauthenticated);
      expect(GraphQLException.kindFor(statusCode: 403),
          GraphQLErrorKind.forbidden);
      expect(GraphQLException.kindFor(statusCode: 422),
          GraphQLErrorKind.invalidRequest);
      expect(
          GraphQLException.kindFor(statusCode: 503), GraphQLErrorKind.server);
    });

    test('other errors on a 200 are execution errors', () {
      expect(
        GraphQLException.kindFor(
            statusCode: 200, errors: [const GraphQLError(message: 'x')]),
        GraphQLErrorKind.graphql,
      );
    });

    test('every kind has a user message', () {
      for (final kind in GraphQLErrorKind.values) {
        expect(GraphQLException(kind, 'x').userMessage, isNotEmpty);
      }
    });
  });

  group('GraphQLResponse.fromJson', () {
    test('parses data, errors and extensions', () {
      final response = GraphQLResponse.fromJson({
        'data': {'a': 1},
        'errors': [
          {
            'message': 'boom',
            'path': ['a', 0],
            'locations': [
              {'line': 1, 'column': 2},
            ],
            'extensions': {'code': 'X'},
          },
        ],
        'extensions': {'cost': 3},
      });
      expect(response.data, {'a': 1});
      expect(response.errors.single.code, 'X');
      expect(response.errors.single.path, ['a', 0]);
      expect(response.errors.single.locations.single,
          const ErrorLocation(line: 1, column: 2));
      expect(response.extensions, {'cost': 3});
    });

    test('rejects bodies that are not GraphQL responses', () {
      expect(
        () => GraphQLResponse.fromJson('<html>Bad gateway</html>'),
        throwsA(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.invalidResponse)),
      );
    });
  });

  group('GraphQLResult', () {
    const success = GraphQLSuccess<int>(2);
    const failure =
        GraphQLFailure<int>(GraphQLException(GraphQLErrorKind.network, 'x'));

    test('accessors', () {
      expect(success.dataOrNull, 2);
      expect(success.isSuccess, isTrue);
      expect(failure.dataOrNull, isNull);
      expect(failure.exceptionOrNull?.kind, GraphQLErrorKind.network);
      expect(() => failure.dataOrThrow, throwsA(isA<GraphQLException>()));
    });

    test('map and when', () {
      expect(success.map((v) => v * 10).dataOrNull, 20);
      expect(failure.map((v) => v * 10).isSuccess, isFalse);
      expect(
          success.when(success: (v) => 'ok $v', failure: (_) => 'no'), 'ok 2');
    });
  });
}
