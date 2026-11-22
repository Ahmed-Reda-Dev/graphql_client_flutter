import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/cli_options.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_config.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';

void main() {
  Matcher error(String text) => throwsA(isA<CodegenException>()
      .having((e) => e.message, 'message', contains(text)));

  test('no options just generates', () {
    final options = CliOptions.parse([]);
    expect(options.download, isFalse);
    expect(options.help, isFalse);
  });

  test('--download with a URL and headers', () {
    final options = CliOptions.parse([
      '--download',
      'https://api.test/graphql',
      '--header',
      'Authorization: Bearer abc:def',
      '--header',
      'X-Team: mobile',
    ]);
    expect(options.download, isTrue);
    expect(options.downloadUrl, Uri.parse('https://api.test/graphql'));
    expect(options.headers, {
      'Authorization': 'Bearer abc:def', // Only the first colon splits.
      'X-Team': 'mobile',
    });
  });

  test('--download alone uses the schema_url setting', () {
    final options = CliOptions.parse(['--download']);
    expect(options.download, isTrue);
    expect(options.downloadUrl, isNull);
  });

  test('mistakes are explained', () {
    expect(() => CliOptions.parse(['--download', 'not a url']),
        error('needs a URL'));
    expect(() => CliOptions.parse(['--download', 'localhost:3000/graphql']),
        error('http://'));
    expect(() => CliOptions.parse(['--header', 'A: b']),
        error('only with --download'));
    expect(() => CliOptions.parse(['--header']), error('Name: value'));
    expect(
        () => CliOptions.parse(['--header', 'NoColon']), error('Name: value'));
    expect(() => CliOptions.parse(['--wat']), error('Unknown option'));
  });

  test('schema_url is read from pubspec.yaml and checked', () {
    final config = CodegenConfig.fromPubspec('''
graphql_client_flutter:
  schema: lib/schema.graphql
  schema_url: https://api.test/graphql
''');
    expect(config.schemaUrl, Uri.parse('https://api.test/graphql'));
    expect(
      () => CodegenConfig.fromPubspec(
          'graphql_client_flutter:\n  schema: s.graphql\n  schema_url: nope\n'),
      error('schema_url'),
    );
    expect(
      () => CodegenConfig.fromPubspec('graphql_client_flutter:\n'
          '  schema: s.graphql\n  schema_url: ftp://api.test/graphql\n'),
      error('schema_url'),
    );
  });
}
