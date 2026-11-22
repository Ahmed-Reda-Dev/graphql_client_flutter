import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/dart_formatter.dart';

/// Compares formatted [source] with the golden file at [path]. Run with
/// `UPDATE_GOLDENS=1` to rewrite it after an intended change.
Future<void> expectGolden(String path, String source) async {
  // Inside the package, so `dart format` uses its language version, as the
  // CI format check does.
  final temp = File('.dart_tool/codegen_golden/${path.split('/').last}')
    ..createSync(recursive: true)
    ..writeAsStringSync(source);
  expect(await formatDartFiles([temp.path]), isTrue,
      reason: 'generated code must be valid Dart:\n$source');
  final formatted = temp.readAsStringSync();
  final golden = File(path);
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    golden.writeAsStringSync(formatted);
  }
  expect(formatted, golden.readAsStringSync(),
      reason: 'Generated code changed; rerun with UPDATE_GOLDENS=1 if '
          'intended');
}
