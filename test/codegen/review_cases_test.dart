// Inputs found in review that the fixtures did not cover.
import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/data_class_writer.dart';
import 'package:graphql_client_flutter/src/codegen/operation_model.dart';
import 'package:graphql_client_flutter/src/codegen/schema_index.dart';
import 'package:graphql_client_flutter/src/codegen/schema_types_writer.dart';
import 'package:graphql_client_flutter/src/codegen/type_mapper.dart';

import 'support.dart';

const _sdl = '''
type Query {
  search: [SearchResult!]!
  node: Node
  settings: Settings!
}
interface Node { id: ID }
type User implements Node { id: ID! name: String! }
type Post implements Node { id: ID title: String! }
union SearchResult = User | Post
type Settings { int: Int! first_name: String firstName: String color: Color! }
enum Color { RED GREEN }
input Range { int: Int! bool: Boolean }
extend type Query { extra: String! }
''';

void main() {
  final schema = SchemaIndex.parse(_sdl);
  final mapper = TypeMapper(schema);

  OperationModel build(String source) {
    final document = parseDocument(source);
    return OperationModelBuilder(schema, {
      for (final f in document.definitions.whereType<FragmentDefinitionNode>())
        f.name.value: f,
    }).build(document.definitions.last as OperationDefinitionNode);
  }

  Matcher error(String text) => throwsA(isA<CodegenException>()
      .having((e) => e.message, 'message', contains(text)));

  test('a fragment on an interface covering a whole union', () {
    final model =
        build('query Q { search { ... on Node { id } ... on User { name } } }');
    final search = model.classes.firstWhere((c) => c.isSealed);
    expect(search.fields.map((f) => f.responseKey), ['id']);
  });

  test('a shared field nullable in one variant is a nullable getter', () {
    final model = build('query Q { node { id ... on User { id name } } }');
    final node = model.classes.firstWhere((c) => c.isSealed);
    expect(node.fields.single.responseKey, 'id');
    expect(node.fields.single.type.isNonNull, isFalse);
  });

  test('fields from `extend type` are known', () {
    expect(build('query Q { extra }').data.fields.single.responseKey, 'extra');
  });

  test('an aliased __typename becomes a String field', () {
    final user = build('query Q { search { t: __typename } }')
        .classes
        .firstWhere((c) => c.typeName == 'SearchResult');
    expect(user.fields.single.dartName, 't');
  });

  test('fields named like Dart types get a suffix', () {
    final source = DataClassWriter(mapper)
        .write(build('query Q { settings { int } }').classes);
    expect(source, contains(r'final int int$;'));
    final input = SchemaTypesWriter(mapper).write(['Range']);
    expect(input, contains(r'final int int$;'));
    expect(input, contains(r'final bool? bool$;'));
  });

  test('two fields with the same Dart name ask for an alias', () {
    expect(() => build('query Q { settings { first_name firstName } }'),
        error('alias'));
  });

  test('data with an unknown enum value can still be written as JSON', () {
    final source = DataClassWriter(mapper)
        .write(build('query Q { settings { color } }').classes);
    expect(source, contains("'color': color.value"));
  });
}
