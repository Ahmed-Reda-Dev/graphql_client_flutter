import 'dart:async';
import 'dart:io';

/// Runs [generate] now, then again whenever [signature] changes, checking
/// every [interval], until [stop] completes.
///
/// Polling keeps it portable (recursive file watching differs between
/// platforms) and is cheap: [signature] only reads file metadata. A
/// [signature] that fails (a file saved by rename vanishing mid-read)
/// counts as unchanged until the next check.
Future<void> watchAndGenerate({
  required Future<void> Function() generate,
  required String Function() signature,
  Duration interval = const Duration(milliseconds: 500),
  Future<void>? stop,
}) async {
  var last = signature();
  await generate();
  var stopped = false;
  unawaited(stop?.then((_) => stopped = true));
  while (!stopped) {
    await Future<void>.delayed(interval);
    if (stopped) break;
    final String now;
    try {
      now = signature();
    } on FileSystemException {
      continue;
    }
    if (now == last) continue;
    last = now;
    await generate();
  }
}
