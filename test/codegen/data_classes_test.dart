import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';

import 'golden.dart';
import 'support.dart';

void main() {
  test('writes data classes for every operation (golden)', () async {
    final document = parseDocument(
      File('test/codegen/fixtures/user.graphql').readAsStringSync(),
      url: 'user.graphql',
    );
    await expectGolden(
      'test/codegen/generated/user.graphql.dart',
      generateDataClasses(document, from: 'user.graphql'),
    );
  });

  test('merges a field selected twice and flattens fragments', () {
    final document = parseDocument('''
      fragment A on User { avatar { url } }
      query Q { user(id: "1") { ...A avatar { width } } }
    ''');
    final model = builderFor(document)
        .build(document.definitions.last as OperationDefinitionNode);
    final avatar = model.classes.firstWhere((c) => c.typeName == 'Image');
    expect(avatar.fields.map((f) => f.responseKey), ['url', 'width']);
  });

  group('reports mistakes with their location', () {
    void expectError(String source, String message, {int? line}) {
      final document = parseDocument(source, url: 'bad.graphql');
      expect(
        () => builderFor(document)
            .build(document.definitions.last as OperationDefinitionNode),
        throwsA(isA<CodegenException>()
            .having((e) => e.message, 'message', contains(message))
            .having((e) => e.toString(), 'location',
                line == null ? anything : startsWith('bad.graphql:$line:'))),
      );
    }

    test('an unknown field', () {
      expectError('query Q {\n  user(id: "1") {\n    nickname\n  }\n}',
          'Type "User" has no field "nickname"',
          line: 3);
    });

    test('an unnamed operation', () {
      expectError('{ user(id: "1") { id } }', 'Name this operation');
    });

    test('an object field without a selection', () {
      expectError('query Q { user(id: "1") }', 'Select fields of "user"');
    });

    test('an unknown fragment', () {
      expectError('query Q { user(id: "1") { ...Missing } }',
          'Unknown fragment "Missing"');
    });
  });
}
