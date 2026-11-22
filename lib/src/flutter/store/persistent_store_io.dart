import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../../core/json.dart';
import 'buffered_store.dart';

/// A [BufferedStore] saved to a file, so cached data survives app restarts
/// and is available offline.
///
/// All entities are loaded into memory by [open]; changes are written back
/// after `writeDelay` (batched) using an atomic replace, so a crash during a
/// write never corrupts the file. On the web the same API saves to
/// `localStorage`.
///
/// **Security:** the file is plain JSON unless you pass a [Codec] that
/// encrypts it (e.g. AES with a key from `flutter_secure_storage`). Use a
/// per-user name, and call `await client.resetStore()` (or `clear` then
/// `flush`) when the user signs out.
///
/// ```dart
/// final client = GraphQLClient(
///   url,
///   cache: GraphQLCache(store: await PersistentStore.open()),
/// );
/// ```
final class PersistentStore extends BufferedStore {
  PersistentStore._(
    this._file,
    super.data, {
    required super.writeDelay,
    super.codec,
    super.onWriteError,
  });

  /// Opens (or creates) the store named [name].
  ///
  /// Files live in the app support directory unless [directoryPath] returns
  /// another one. A corrupt file is discarded and the store starts empty.
  static Future<PersistentStore> open({
    String name = 'graphql_cache',
    Duration writeDelay = const Duration(milliseconds: 300),
    Future<String> Function()? directoryPath,
    Codec<String, String>? codec,
    WriteErrorHandler? onWriteError,
  }) async {
    BufferedStore.checkName(name);
    final directory = directoryPath != null
        ? await directoryPath()
        : (await getApplicationSupportDirectory()).path;
    await Directory(directory).create(recursive: true);
    final file = File('$directory/$name.json');
    // A crash between writing the temp file and renaming it leaves it behind.
    final leftover = File('${file.path}.tmp');
    if (await leftover.exists()) await leftover.delete();
    return PersistentStore._(
      file,
      await _load(file, codec),
      writeDelay: writeDelay,
      codec: codec,
      onWriteError: onWriteError,
    );
  }

  final File _file;

  /// Files at least this large are decoded in a background isolate, so a
  /// big cache does not drop frames at startup.
  static const _isolateDecodingThreshold = 50 * 1024;

  @override
  Future<void> persist(String contents) async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(_file.path);
  }

  static Future<Map<String, JsonMap>> _load(
    File file,
    Codec<String, String>? codec,
  ) async {
    if (!await file.exists()) return {};
    // A codec may hold objects that cannot be sent to an isolate, so only
    // plain files are decoded in the background.
    final path = file.path;
    final data =
        codec == null && await file.length() >= _isolateDecodingThreshold
            ? await Isolate.run(
                () => BufferedStore.decode(File(path).readAsStringSync(), null),
              )
            : BufferedStore.decode(await file.readAsString(), codec);
    if (data == null) {
      // Corrupt, or written with a different codec/key: start empty.
      await file.delete();
      return {};
    }
    return data;
  }
}
