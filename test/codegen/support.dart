import 'dart:io';

import 'package:gql/ast.dart';
import 'package:gql/language.dart' as gql;
import 'package:graphql_client_flutter/src/codegen/data_class_writer.dart';
import 'package:graphql_client_flutter/src/codegen/generated_file.dart';
import 'package:graphql_client_flutter/src/codegen/operation_model.dart';
import 'package:graphql_client_flutter/src/codegen/schema_index.dart';
import 'package:graphql_client_flutter/src/codegen/type_mapper.dart';

/// The fixture schema.
final fixtureSchema = SchemaIndex.parse(
  File('test/codegen/fixtures/schema.graphql').readAsStringSync(),
);

/// A mapper over [fixtureSchema] with `DateTime` mapped.
final fixtureMapper =
    TypeMapper(fixtureSchema, scalars: {'DateTime': 'DateTime'});

/// Parses [source] as a document named [url].
DocumentNode parseDocument(String source, {String url = 'test.graphql'}) =>
    gql.parseString(source, url: url);

/// A builder knowing [document]'s fragments.
OperationModelBuilder builderFor(DocumentNode document) =>
    OperationModelBuilder(fixtureSchema, {
      for (final f in document.definitions.whereType<FragmentDefinitionNode>())
        f.name.value: f,
    });

/// The data classes generated for every operation in [document].
String generateDataClasses(DocumentNode document, {required String from}) {
  final builder = builderFor(document);
  final classes = [
    for (final operation
        in document.definitions.whereType<OperationDefinitionNode>())
      ...builder.build(operation).classes,
  ];
  return generatedFile(
    DataClassWriter(fixtureMapper).write(classes),
    from: from,
    imports: ['schema.graphql.dart'],
  );
}
