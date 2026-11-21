import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import '../client/graphql_observer.dart';
import '../json.dart';
import '../request/graphql_request.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';

/// Whether DevTools support is compiled in: debug and profile builds only.
/// In release builds the bridge code is tree-shaken away.
const bool devToolsEnabled = !bool.fromEnvironment('dart.vm.product');

/// What the bridge needs from a client, without depending on it.
abstract interface class DevToolsTarget {
  /// A short description shown in DevTools.
  String get label;

  /// The normalized cache contents, by entity id.
  Map<String, JsonMap?> cacheSnapshot();

  /// Clears the client's cache.
  void clearCache();
}

/// Connects clients to Dart DevTools.
///
/// It records recent operations, posts an event for each one (shown live by
/// the graphql_client_flutter DevTools extension), adds them to the
/// Performance timeline, and answers service extension calls:
///
/// - `ext.graphql_client_flutter.getClients`
/// - `ext.graphql_client_flutter.getOperations`
/// - `ext.graphql_client_flutter.getCache` (`clientId`)
/// - `ext.graphql_client_flutter.clearCache` (`clientId`)
/// - `ext.graphql_client_flutter.clearOperations`
final class DevToolsBridge {
  DevToolsBridge._();

  /// The bridge for this isolate.
  static final DevToolsBridge instance = DevToolsBridge._();

  /// Extension event kind for operations.
  static const operationEvent = 'graphql_client_flutter:operation';

  static const _prefix = 'ext.graphql_client_flutter.';
  static const _maxOperations = 200;

  final Map<int, DevToolsTarget> _clients = {};
  final ListQueue<JsonMap> _operations = ListQueue();
  int _nextClientId = 0;
  bool _extensionsRegistered = false;

  /// Registers a client and returns its id.
  int register(DevToolsTarget target) {
    _registerExtensions();
    final id = ++_nextClientId;
    _clients[id] = target;
    return id;
  }

  /// Unregisters a disposed client.
  void unregister(int clientId) => _clients.remove(clientId);

  /// Records an operation event and sends it to DevTools.
  void record(JsonMap event) {
    _operations.addLast(event);
    while (_operations.length > _maxOperations) {
      _operations.removeFirst();
    }
    developer.postEvent(operationEvent, event);
  }

  /// Answers a service extension call. Public for testing.
  JsonMap handle(String method, Map<String, String> parameters) {
    switch (method) {
      case 'getClients':
        return {
          'clients': [
            for (final MapEntry(:key, :value) in _clients.entries)
              {'id': key, 'label': value.label},
          ],
        };
      case 'getOperations':
        return {'operations': _operations.toList()};
      case 'clearOperations':
        _operations.clear();
        return {'ok': true};
      case 'getCache':
        final target = _target(parameters);
        return {'entities': target?.cacheSnapshot() ?? const {}};
      case 'clearCache':
        _target(parameters)?.clearCache();
        return {'ok': true};
      default:
        throw ArgumentError.value(method, 'method', 'Unknown method');
    }
  }

  DevToolsTarget? _target(Map<String, String> parameters) {
    final id = int.tryParse(parameters['clientId'] ?? '');
    return id == null ? _clients.values.lastOrNull : _clients[id];
  }

  void _registerExtensions() {
    if (_extensionsRegistered) return;
    _extensionsRegistered = true;
    for (final method in const [
      'getClients',
      'getOperations',
      'clearOperations',
      'getCache',
      'clearCache',
    ]) {
      try {
        developer.registerExtension('$_prefix$method', (_, parameters) async {
          try {
            return developer.ServiceExtensionResponse.result(
              jsonEncode(handle(method, parameters)),
            );
          } catch (e) {
            return developer.ServiceExtensionResponse.error(
              developer.ServiceExtensionResponse.extensionError,
              '$e',
            );
          }
        });
      } on ArgumentError {
        // Already registered (e.g. after a hot restart in the same isolate).
      }
    }
  }
}

/// Feeds a client's operations to [DevToolsBridge] and the timeline.
final class DevToolsObserver extends GraphQLObserver {
  /// Creates an observer for the client registered as [clientId].
  DevToolsObserver(this.clientId, [DevToolsBridge? bridge])
      : _bridge = bridge ?? DevToolsBridge.instance;

  /// The client's id in the bridge.
  final int clientId;

  final DevToolsBridge _bridge;
  final Expando<_Started> _started = Expando();
  int _nextId = 0;

  @override
  void onRequest(GraphQLRequest request) {
    final id = '$clientId-${++_nextId}';
    final name = request.operationName ?? request.type.name;
    final task = developer.TimelineTask()
      ..start('GraphQL $name', arguments: {'type': request.type.name});
    _started[request] = _Started(id, task);
    _bridge.record({
      ...describe(request, clientId, id),
      'status': 'pending',
    });
  }

  @override
  void onResponse(
    GraphQLRequest request,
    GraphQLResponse response,
    Duration elapsed,
  ) {
    final started = _started[request];
    started?.task.finish(arguments: {
      'status': '${response.statusCode}',
      'errors': '${response.errors.length}',
    });
    _bridge.record({
      ...describe(request, clientId, started?.id),
      'status': response.hasErrors ? 'errors' : 'success',
      'durationMs': elapsed.inMilliseconds,
      'httpStatus': response.statusCode,
      'data': response.data,
      'errors': [for (final error in response.errors) error.toJson()],
    });
  }

  @override
  void onError(
    GraphQLRequest request,
    GraphQLException exception,
    Duration elapsed,
  ) {
    final started = _started[request];
    started?.task.finish(arguments: {'error': exception.kind.name});
    _bridge.record({
      ...describe(request, clientId, started?.id),
      'status': 'failure',
      'durationMs': elapsed.inMilliseconds,
      'errorKind': exception.kind.name,
      'message': exception.message,
    });
  }

  @override
  void onCacheHit(GraphQLRequest request) {
    _bridge.record({
      ...describe(request, clientId, '$clientId-${++_nextId}'),
      'status': 'cache',
      'durationMs': 0,
    });
  }

  /// The fields every operation event shares.
  static JsonMap describe(GraphQLRequest request, int clientId, String? id) => {
        'id': id,
        'clientId': clientId,
        'time': DateTime.now().toIso8601String(),
        'type': request.type.name,
        'operationName': request.operationName,
        'variables': request.variables,
        'document': request.document.printed,
      };
}

final class _Started {
  _Started(this.id, this.task);

  final String id;
  final developer.TimelineTask task;
}
