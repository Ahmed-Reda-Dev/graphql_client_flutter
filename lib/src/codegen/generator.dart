import 'dart:io';

import 'package:gql/ast.dart';
import 'package:gql/language.dart' as gql;
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';

import 'codegen_config.dart';
import 'codegen_exception.dart';
import 'dart_formatter.dart';
import 'data_class_writer.dart';
import 'generated_file.dart';
import 'operation_model.dart';
import 'operation_writer.dart';
import 'schema_index.dart';
import 'schema_types_writer.dart';
import 'type_mapper.dart';

/// What a [Generator] run wrote and deleted.
final class GenerationReport {
  /// Creates a report.
  const GenerationReport({required this.written, required this.deleted});

  /// Generated files, relative to the project.
  final List<String> written;

  /// Stale generated files removed (their `.graphql` file is gone or has
  /// no operations left).
  final List<String> deleted;
}

/// Generates Dart for a project: one `.graphql.dart` file next to each
/// `.graphql` document, and one next to the schema for shared enums and
/// inputs.
final class Generator {
  /// Creates a generator for the project in [root].
  Generator(this.config, {this.root = '.'});

  /// The settings.
  final CodegenConfig config;

  /// The project folder.
  final String root;

  static const _header = '// GENERATED CODE - DO NOT MODIFY BY HAND.';

  /// Generates every file and formats them.
  ///
  /// Throws a [CodegenException] (with the file and line) for a problem in
  /// the schema or a document; nothing is written then.
  Future<GenerationReport> run() async {
    final schemaFile = File(p.join(root, config.schema));
    if (!schemaFile.existsSync()) {
      throw CodegenException('Schema file not found: ${config.schema}');
    }
    final schema = SchemaIndex.parse(
      schemaFile.readAsStringSync(),
      url: config.schema,
    );
    final mapper = TypeMapper(schema, scalars: config.scalars);
    final documents = _readDocuments(schemaFile.path);
    final fragments = _fragments(documents);
    final builder = OperationModelBuilder(schema, fragments);
    final operationWriter = OperationWriter(mapper, fragments);
    final dataWriter = DataClassWriter(mapper);
    final schemaTypes = SchemaTypesWriter(mapper);
    final schemaDart = '${schemaFile.path}.dart';

    // Build everything first, so an error leaves the project untouched.
    final outputs = <String, String>{};
    final operationNames = <String, OperationDefinitionNode>{};
    final variableTypes = <String>{};
    for (final MapEntry(key: path, value: document) in documents.entries) {
      final operations = [
        for (final node
            in document.definitions.whereType<OperationDefinitionNode>())
          builder.build(_unique(node, operationNames)),
      ];
      if (operations.isEmpty) continue;
      final body = StringBuffer();
      for (final operation in operations) {
        variableTypes.addAll([
          for (final v in operation.node.variableDefinitions) baseName(v.type),
        ]);
        body
          ..write(operationWriter.write(operation))
          ..write(dataWriter.write(operation.classes));
      }
      outputs['$path.dart'] = generatedFile(
        body.toString(),
        from: p.relative(path, from: root),
        imports: [
          p.url.joinAll(p.split(p.relative(schemaDart, from: p.dirname(path)))),
        ],
      );
    }
    outputs[schemaDart] = generatedFile(
      schemaTypes.write(
        schemaTypes.reachable({...variableTypes, ...builder.usedEnums}),
      ),
      from: config.schema,
    );

    final deleted = _deleteStale(outputs.keys.toSet());
    for (final MapEntry(key: path, value: source) in outputs.entries) {
      File(path).writeAsStringSync(source);
    }
    await formatDartFiles(outputs.keys);
    return GenerationReport(
      written: [for (final path in outputs.keys) p.relative(path, from: root)],
      deleted: deleted,
    );
  }

  /// Every `.graphql` file under the include folders, except the schema,
  /// parsed, by path (sorted, so output is stable).
  Map<String, DocumentNode> _readDocuments(String schemaPath) {
    final paths = <String>[];
    for (final folder in config.include) {
      final directory = Directory(p.join(root, folder));
      if (!directory.existsSync()) continue;
      paths.addAll([
        for (final entity in directory.listSync(recursive: true))
          if (entity is File &&
              entity.path.endsWith('.graphql') &&
              !p.equals(entity.path, schemaPath))
            entity.path,
      ]);
    }
    paths.sort();
    return {
      for (final path in paths) path: _parse(path),
    };
  }

  DocumentNode _parse(String path) {
    try {
      return gql.parseString(
        File(path).readAsStringSync(),
        url: p.relative(path, from: root),
      );
    } on SourceSpanException catch (e) {
      throw CodegenException(e.message, e.span);
    }
  }

  /// All fragment definitions by name; names must be unique.
  static Map<String, FragmentDefinitionNode> _fragments(
    Map<String, DocumentNode> documents,
  ) {
    final fragments = <String, FragmentDefinitionNode>{};
    for (final document in documents.values) {
      for (final fragment
          in document.definitions.whereType<FragmentDefinitionNode>()) {
        final name = fragment.name.value;
        if (fragments.containsKey(name)) {
          throw CodegenException(
            'Another fragment is already named "$name"',
            fragment.name.span,
          );
        }
        fragments[name] = fragment;
      }
    }
    return fragments;
  }

  /// Checks [node]'s name is unique across documents.
  static OperationDefinitionNode _unique(
    OperationDefinitionNode node,
    Map<String, OperationDefinitionNode> seen,
  ) {
    final name = node.name?.value;
    if (name != null && seen.containsKey(name)) {
      throw CodegenException(
        'Another operation is already named "$name"',
        node.name?.span,
      );
    }
    if (name != null) seen[name] = node;
    return node;
  }

  /// Deletes generated `.graphql.dart` files under the include folders that
  /// this run does not write. Only files with the generated header are
  /// touched.
  List<String> _deleteStale(Set<String> outputs) {
    final deleted = <String>[];
    for (final folder in config.include) {
      final directory = Directory(p.join(root, folder));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File ||
            !entity.path.endsWith('.graphql.dart') ||
            outputs.any((o) => p.equals(o, entity.path))) {
          continue;
        }
        final firstLine = entity.readAsLinesSync().firstOrNull;
        if (firstLine == _header) {
          entity.deleteSync();
          deleted.add(p.relative(entity.path, from: root));
        }
      }
    }
    return deleted;
  }
}
