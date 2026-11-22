import 'package:yaml/yaml.dart';

import 'codegen_exception.dart';

/// Code generation settings, read from the `graphql_client_flutter`
/// section of `pubspec.yaml`:
///
/// ```yaml
/// graphql_client_flutter:
///   schema: lib/graphql/schema.graphql
///   include: [lib]            # folders searched for .graphql files
///   scalars:
///     DateTime: DateTime      # String, int, double, num, bool, DateTime, Object
/// ```
final class CodegenConfig {
  /// Creates settings.
  const CodegenConfig({
    required this.schema,
    this.include = const ['lib'],
    this.scalars = const {},
  });

  /// Reads the `graphql_client_flutter` section of [pubspec] (its text).
  factory CodegenConfig.fromPubspec(String pubspec) {
    final Object? yaml;
    try {
      yaml = loadYaml(pubspec);
    } on YamlException catch (e) {
      throw CodegenException('pubspec.yaml: ${e.message}', e.span);
    }
    final section = yaml is YamlMap ? yaml[_section] : null;
    if (section is! YamlMap) {
      throw const CodegenException(
        'Add a "$_section" section to pubspec.yaml, e.g.:\n\n'
        '$_section:\n'
        '  schema: lib/graphql/schema.graphql\n',
      );
    }
    final schema = section['schema'];
    if (schema is! String || schema.isEmpty) {
      throw const CodegenException(
        '$_section.schema must be the path of your schema (SDL) file',
      );
    }
    final include = section['include'];
    final scalars = section['scalars'];
    return CodegenConfig(
      schema: schema,
      include: switch (include) {
        null => const ['lib'],
        final String folder => [folder],
        final YamlList folders => [for (final f in folders) '$f'],
        _ => throw const CodegenException(
            '$_section.include must be a folder or a list of folders',
          ),
      },
      scalars: switch (scalars) {
        null => const {},
        final YamlMap map => {
            for (final MapEntry(:key, :value) in map.entries) '$key': '$value',
          },
        _ => throw const CodegenException(
            '$_section.scalars must map scalar names to Dart types',
          ),
      },
    );
  }

  static const _section = 'graphql_client_flutter';

  /// The schema file, relative to the project.
  final String schema;

  /// Folders searched (recursively) for `.graphql` documents.
  final List<String> include;

  /// Custom scalar names mapped to Dart types.
  final Map<String, String> scalars;
}
