export 'buffered_store.dart' show BufferedStore, WriteErrorHandler;
export 'persistent_store_memory.dart'
    if (dart.library.io) 'persistent_store_io.dart'
    if (dart.library.js_interop) 'persistent_store_web.dart';
