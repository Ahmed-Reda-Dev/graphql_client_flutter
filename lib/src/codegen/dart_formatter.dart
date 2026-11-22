import 'dart:io';

/// Formats [paths] with `dart format`, so generated code reads like
/// hand-written code. Returns false if the formatter could not run (the
/// files are then left as generated).
Future<bool> formatDartFiles(Iterable<String> paths) async {
  final files = paths.toList();
  if (files.isEmpty) return true;
  try {
    final result = await Process.run(
      Platform.resolvedExecutable.endsWith('dart') ||
              Platform.resolvedExecutable.endsWith('dart.exe')
          ? Platform.resolvedExecutable
          : 'dart',
      ['format', ...files],
    );
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
