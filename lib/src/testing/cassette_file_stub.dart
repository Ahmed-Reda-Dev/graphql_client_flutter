/// Reads the text file at [path]: unsupported without `dart:io`.
Future<String> read(String path) => throw UnsupportedError(_message);

/// Writes [contents] to [path]: unsupported without `dart:io`.
Future<void> write(String path, String contents) =>
    throw UnsupportedError(_message);

const _message = 'Cassette files need dart:io. On the web, use '
    'Cassette.toJson and Cassette.fromJson instead.';
