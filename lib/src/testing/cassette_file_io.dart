import 'dart:io';

/// Reads the text file at [path].
Future<String> read(String path) => File(path).readAsString();

/// Writes [contents] to [path], creating missing folders.
Future<void> write(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}
