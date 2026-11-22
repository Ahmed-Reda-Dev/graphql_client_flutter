import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_config.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/generator.dart';

void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('codegen_project');
    _write(project, 'lib/graphql/schema.graphql',
        File('test/codegen/fixtures/schema.graphql').readAsStringSync());
  });

  tearDown(() => project.delete(recursive: true));

  Future<GenerationReport> generate() => Generator(
        const CodegenConfig(
          schema: 'lib/graphql/schema.graphql',
          scalars: {'DateTime': 'DateTime'},
        ),
        root: project.path,
      ).run();

  String read(String path) => File('${project.path}/$path').readAsStringSync();

  test('writes a file per document, importing the shared schema types',
      () async {
    _write(project, 'lib/features/user/user.graphql',
        r'query GetUser($id: ID!) { user(id: $id) { id role } }');

    final report = await generate();

    expect(
        report.written,
        unorderedEquals([
          'lib/features/user/user.graphql.dart',
          'lib/graphql/schema.graphql.dart',
        ]));
    final user = read('lib/features/user/user.graphql.dart');
    expect(user, contains("import '../../graphql/schema.graphql.dart';"));
    expect(user, contains('extension GetUserOperation on GraphQLClient'));
    expect(read('lib/graphql/schema.graphql.dart'), contains('enum Role'));
  });

  test('fragments may live in another file', () async {
    _write(project, 'lib/fragments.graphql', 'fragment F on User { id name }');
    _write(project, 'lib/user.graphql',
        'query GetUser { user(id: "1") { ...F } }');

    final report = await generate();

    expect(report.written, isNot(contains('lib/fragments.graphql.dart')));
    expect(read('lib/user.graphql.dart'), contains('fragment F on User'));
  });

  test('a mistake writes nothing and names the file and line', () async {
    _write(project, 'lib/ok.graphql', 'query Ok { user(id: "1") { id } }');
    _write(project, 'lib/bad.graphql',
        'query Bad {\n  user(id: "1") { nickname }\n}');

    await expectLater(
      generate(),
      throwsA(isA<CodegenException>().having(
          (e) => e.toString(), 'toString', startsWith('lib/bad.graphql:2'))),
    );
    expect(File('${project.path}/lib/ok.graphql.dart').existsSync(), isFalse);
  });

  test('operation and fragment names must be unique across files', () async {
    _write(project, 'lib/a.graphql', 'query Same { user(id: "1") { id } }');
    _write(project, 'lib/b.graphql', 'query Same { user(id: "2") { id } }');

    await expectLater(
      generate(),
      throwsA(isA<CodegenException>()
          .having((e) => e.message, 'message', contains('"Same"'))),
    );
  });

  test('removes generated files whose document is gone, and only those',
      () async {
    _write(project, 'lib/old.graphql', 'query Old { user(id: "1") { id } }');
    await generate();
    _write(project, 'lib/mine.graphql.dart', '// Hand-written, keep me.\n');
    File('${project.path}/lib/old.graphql').deleteSync();

    final report = await generate();

    expect(report.deleted, ['lib/old.graphql.dart']);
    expect(File('${project.path}/lib/mine.graphql.dart').existsSync(), isTrue);
  });

  test('a missing schema file is reported', () async {
    File('${project.path}/lib/graphql/schema.graphql').deleteSync();
    await expectLater(
      generate(),
      throwsA(isA<CodegenException>().having(
          (e) => e.message, 'message', contains('Schema file not found'))),
    );
  });

  group('settings from pubspec.yaml', () {
    test('reads schema, include folders and scalars', () {
      final config = CodegenConfig.fromPubspec('''
name: app
graphql_client_flutter:
  schema: graphql/schema.graphql
  include: [lib, test]
  scalars:
    DateTime: DateTime
''');
      expect(config.schema, 'graphql/schema.graphql');
      expect(config.include, ['lib', 'test']);
      expect(config.scalars, {'DateTime': 'DateTime'});
    });

    test('include defaults to lib and accepts a single folder', () {
      expect(
        CodegenConfig.fromPubspec(
                'graphql_client_flutter:\n  schema: s.graphql\n')
            .include,
        ['lib'],
      );
      expect(
        CodegenConfig.fromPubspec(
                'graphql_client_flutter:\n  schema: s.graphql\n  include: src\n')
            .include,
        ['src'],
      );
    });

    test('a missing section explains what to add', () {
      expect(
        () => CodegenConfig.fromPubspec('name: app\n'),
        throwsA(isA<CodegenException>().having(
            (e) => e.message, 'message', contains('schema: lib/graphql'))),
      );
    });
  });
}

void _write(Directory root, String path, String contents) =>
    (File('${root.path}/$path')..createSync(recursive: true))
        .writeAsStringSync(contents);
