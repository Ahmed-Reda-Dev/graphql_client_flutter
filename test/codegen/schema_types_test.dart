import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/generated_file.dart';
import 'package:graphql_client_flutter/src/codegen/schema_index.dart';
import 'package:graphql_client_flutter/src/codegen/schema_types_writer.dart';
import 'package:graphql_client_flutter/src/codegen/type_mapper.dart';

import 'golden.dart';

void main() {
  final schema = SchemaIndex.parse(
    File('test/codegen/fixtures/schema.graphql').readAsStringSync(),
  );
  final mapper = TypeMapper(schema, scalars: {'DateTime': 'DateTime'});
  final writer = SchemaTypesWriter(mapper);

  test('finds the enums and inputs reachable from variable types', () {
    expect(writer.reachable(['CreateUserInput']),
        {'CreateUserInput', 'Role', 'UserFilter'});
    expect(writer.reachable(['ID', 'String']), isEmpty);
  });

  test('writes enums and inputs (golden)', () async {
    final names = writer.reachable(['CreateUserInput']);
    await expectGolden(
      'test/codegen/generated/schema.graphql.dart',
      generatedFile(writer.write(names), from: 'schema.graphql'),
    );
  });

  test('maps types to Dart', () {
    TypeMapper m([Map<String, String> scalars = const {}]) =>
        TypeMapper(schema, scalars: scalars);
    final user = schema.field('User', 'createdAt')!.type;
    expect(m().dartType(user), 'Object');
    expect(m({'DateTime': 'DateTime'}).dartType(user), 'DateTime');
    expect(
        m().dartType(schema.field('User', 'scores')!.type), 'List<double?>?');
  });

  test('rejects a scalar mapped to an unsupported type', () {
    expect(
      () => TypeMapper(schema, scalars: {'DateTime': 'Instant'}),
      throwsA(isA<CodegenException>()
          .having((e) => e.message, 'message', contains('Instant'))),
    );
  });

  test('schema syntax errors point at the line', () {
    expect(
      () => SchemaIndex.parse('type Query {\n  user: \n}', url: 'bad.graphql'),
      throwsA(isA<CodegenException>().having(
          (e) => e.toString(), 'toString', startsWith('bad.graphql:3'))),
    );
  });
}
