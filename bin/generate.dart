// Generates typed Dart for the .graphql files of a project.
//
//   dart run graphql_client_flutter:generate
import 'dart:io';

import 'package:graphql_client_flutter/src/codegen/codegen_config.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/generator.dart';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  try {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      throw const CodegenException(
        'Run this from your project folder (no pubspec.yaml here)',
      );
    }
    final config = CodegenConfig.fromPubspec(pubspec.readAsStringSync());
    final report = await Generator(config).run();
    for (final path in report.written) {
      stdout.writeln('  wrote   $path');
    }
    for (final path in report.deleted) {
      stdout.writeln('  deleted $path');
    }
    stdout.writeln('Generated ${report.written.length} files.');
    if (!report.formatted) {
      stderr.writeln('warning: `dart format` could not run; the files are '
          'valid but unformatted.');
    }
  } on CodegenException catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  }
}

const _usage = '''
Generates typed Dart for the .graphql files of a Flutter or Dart project.

Usage: dart run graphql_client_flutter:generate

Settings, in pubspec.yaml:

  graphql_client_flutter:
    schema: lib/graphql/schema.graphql   # required (SDL)
    include: [lib]                       # folders with .graphql files
    scalars:                             # custom scalar -> Dart type
      DateTime: DateTime                 # String, int, double, num, bool,
                                         # DateTime or Object (default)

Each foo.graphql gets a foo.graphql.dart next to it, and the schema gets
one with the enums and input types the operations use.''';
