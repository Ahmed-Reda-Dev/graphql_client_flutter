// Generates typed Dart for the .graphql files of a project.
//
//   dart run graphql_client_flutter:generate [--download [url]]
import 'dart:io';

import 'package:graphql_client_flutter/src/codegen/cli_options.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_config.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/generator.dart';
import 'package:graphql_client_flutter/src/codegen/introspection.dart';

Future<void> main(List<String> args) async {
  try {
    final options = CliOptions.parse(args);
    if (options.help) {
      stdout.writeln(_usage);
      return;
    }
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      throw const CodegenException(
        'Run this from your project folder (no pubspec.yaml here)',
      );
    }
    final config = CodegenConfig.fromPubspec(pubspec.readAsStringSync());
    if (options.download) await _download(config, options);
    await _generate(config);
  } on CodegenException catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  }
}

Future<void> _download(CodegenConfig config, CliOptions options) async {
  final url = options.downloadUrl ?? config.schemaUrl;
  if (url == null) {
    throw const CodegenException(
      'Pass the endpoint (--download https://api.example.com/graphql) or set '
      'graphql_client_flutter.schema_url in pubspec.yaml',
    );
  }
  stdout.writeln('Downloading the schema from $url...');
  final sdl = await downloadSchema(url, headers: options.headers);
  (File(config.schema)..createSync(recursive: true)).writeAsStringSync(sdl);
  stdout.writeln('  wrote   ${config.schema}');
}

Future<void> _generate(CodegenConfig config) async {
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
}

const _usage = '''
Generates typed Dart for the .graphql files of a Flutter or Dart project.

Usage: dart run graphql_client_flutter:generate [options]

Options:
  --download [url]        Download the schema (introspection) first, from
                          url or the schema_url setting.
  --header "Name: value"  Send a header with --download (repeatable),
                          e.g. --header "Authorization: Bearer \$TOKEN".
  -h, --help              Show this help.

Settings, in pubspec.yaml:

  graphql_client_flutter:
    schema: lib/graphql/schema.graphql   # required (SDL)
    schema_url: https://api.example.com/graphql   # for --download
    include: [lib]                       # folders with .graphql files
    scalars:                             # custom scalar -> Dart type
      DateTime: DateTime                 # String, int, double, num, bool,
                                         # DateTime or Object (default)

Each foo.graphql gets a foo.graphql.dart next to it, and the schema gets
one with the enums and input types the operations use.''';
