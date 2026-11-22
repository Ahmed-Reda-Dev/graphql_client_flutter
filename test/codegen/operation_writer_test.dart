import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/operation_writer.dart';

import 'support.dart';

void main() {
  String write(String source) {
    final document = parseDocument(source, url: 'ops.graphql');
    final builder = builderFor(document);
    return OperationWriter(fixtureMapper, builder.fragments).write(
      builder.build(document.definitions.single as OperationDefinitionNode),
    );
  }

  Matcher error(String text) => throwsA(isA<CodegenException>()
      .having((e) => e.message, 'message', contains(text)));

  test('an operation named like a client member must be renamed', () {
    expect(() => write('query Query { user(id: "1") { id } }'),
        error('GraphQLClient already has'));
  });

  test('a variable named like an option must be renamed', () {
    expect(
      () => write(
          r'query Q($headers: String) { search(term: $headers) { __typename } }'),
      error('clashes with the generated "headers" option'),
    );
  });

  test('a variable with a default value is optional', () {
    final source =
        write(r'query Q($first: Int! = 5) { users(first: $first) { id } }');
    expect(source, contains('int? first'));
    expect(source, isNot(contains('required int first')));
  });
}
