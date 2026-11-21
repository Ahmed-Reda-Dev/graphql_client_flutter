import 'dart:async';

import 'package:devtools_extensions/devtools_extensions.dart';

typedef Json = Map<String, dynamic>;

/// Talks to the `ext.graphql_client_flutter.*` service extensions that the
/// package registers in the running app.
///
/// Every call waits for DevTools to finish connecting to the app first: the
/// extension's widgets are built before the VM service is available.
abstract final class Bridge {
  static const _prefix = 'ext.graphql_client_flutter.';
  static const operationEvent = 'graphql_client_flutter:operation';

  static Future<Json> call(String method, [Map<String, String>? args]) async {
    await serviceManager.onServiceAvailable;
    final response = await serviceManager.callServiceExtensionOnMainIsolate(
      '$_prefix$method',
      args: args,
    );
    return response.json ?? const {};
  }

  /// Operation events posted by the app, as they happen.
  static Stream<Json> operationEvents() async* {
    final service = await serviceManager.onServiceAvailable;
    yield* service.onExtensionEvent
        .where((event) => event.extensionKind == operationEvent)
        .map((event) => event.extensionData?.data ?? const <String, dynamic>{});
  }
}
