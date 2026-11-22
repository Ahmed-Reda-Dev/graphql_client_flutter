import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/cli_options.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_config.dart';
import 'package:graphql_client_flutter/src/codegen/generator.dart';
import 'package:graphql_client_flutter/src/codegen/watch.dart';

void main() {
  test('generates at once, then only when the inputs change', () async {
    var signature = 'a';
    var runs = 0;
    final stop = Completer<void>();

    final watching = watchAndGenerate(
      signature: () => signature,
      generate: () async => runs++,
      interval: const Duration(milliseconds: 5),
      stop: stop.future,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(runs, 1); // Unchanged inputs: no regeneration.

    signature = 'b';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(runs, 2);

    stop.complete();
    await watching;
  });

  group('inputsSignature', () {
    late Directory project;
    late Generator generator;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('watch_project');
      File('${project.path}/lib/schema.graphql')
        ..createSync(recursive: true)
        ..writeAsStringSync(
            File('test/codegen/fixtures/schema.graphql').readAsStringSync());
      File('${project.path}/lib/user.graphql')
          .writeAsStringSync('query Q { user(id: "1") { id } }');
      generator = Generator(
        const CodegenConfig(schema: 'lib/schema.graphql'),
        root: project.path,
      );
    });

    tearDown(() => project.delete(recursive: true));

    test('changes when a document is edited or added', () {
      final before = generator.inputsSignature();
      File('${project.path}/lib/user.graphql')
          .writeAsStringSync('query Q { user(id: "1") { id name } }');
      final edited = generator.inputsSignature();
      File('${project.path}/lib/more.graphql')
          .writeAsStringSync('query M { user(id: "2") { id } }');

      expect(edited, isNot(before));
      expect(generator.inputsSignature(), isNot(edited));
    });

    test('is not changed by the files it generates (no endless loop)',
        () async {
      final before = generator.inputsSignature();
      await generator.run();
      expect(generator.inputsSignature(), before);
    });
  });

  test('-w and --watch turn watching on', () {
    expect(CliOptions.parse(['-w']).watch, isTrue);
    expect(CliOptions.parse(['--watch']).watch, isTrue);
    expect(CliOptions.parse([]).watch, isFalse);
  });
}
