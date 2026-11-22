import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';

import 'golden.dart';
import 'support.dart';

void main() {
  final document = parseDocument(
    File('test/codegen/fixtures/search.graphql').readAsStringSync(),
    url: 'search.graphql',
  );
  final operations =
      document.definitions.whereType<OperationDefinitionNode>().toList();

  test('writes sealed classes for unions and interfaces (golden)', () async {
    await expectGolden(
      'test/codegen/generated/search.graphql.dart',
      generateDataClasses(document, from: 'search.graphql'),
    );
  });

  test('one variant per targeted type, plus a fallback', () {
    final model = builderFor(document).build(operations[0]);
    final search =
        model.classes.firstWhere((c) => c.name == r'SearchData$Search');
    expect(search.isSealed, isTrue);
    expect(search.variants.map((v) => v.name), [
      r'SearchData$Search$Post',
      r'SearchData$Search$User',
      r'SearchData$Search$Unknown',
    ]);
  });

  test('fields every variant shares are declared on the sealed class', () {
    final model = builderFor(document).build(operations[3]);
    final entries =
        model.classes.firstWhere((c) => c.name == r'EntriesData$Entries');
    expect(entries.fields.map((f) => f.responseKey), ['id', 'owner']);
  });

  test('an interface without type-specific fragments is a plain class', () {
    final model = builderFor(document).build(operations[2]);
    final node = model.classes.firstWhere((c) => c.typeName == 'Node');
    expect(node.isSealed, isFalse);
    expect(node.keepsTypename, isTrue);
  });

  test('two classes with the same name ask for an alias', () {
    final clash = parseDocument(
      'query C { entries { post: owner { name } ... on Post { title } } }',
    );
    expect(
      () => builderFor(clash)
          .build(clash.definitions.single as OperationDefinitionNode),
      throwsA(isA<CodegenException>()
          .having((e) => e.message, 'message', contains('alias'))),
    );
  });
}
