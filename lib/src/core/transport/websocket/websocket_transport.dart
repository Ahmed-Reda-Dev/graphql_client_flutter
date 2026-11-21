import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../json.dart';
import '../../request/cancellation_token.dart';
import '../../request/graphql_request.dart';
import '../../response/graphql_error.dart';
import '../../response/graphql_exception.dart';
import '../../response/graphql_response.dart';
import '../graphql_transport.dart';
import 'subscription_protocol.dart';

/// Opens a WebSocket. Override to add headers or use a custom channel.
typedef WebSocketChannelFactory = WebSocketChannel Function(
  Uri uri,
  Iterable<String> protocols,
);

/// Supplies the `connection_init` payload. Called for every (re)connection,
/// so it can return a freshly refreshed token.
typedef ConnectionParamsProvider = FutureOr<JsonMap> Function();

enum _State { idle, connecting, connected }

/// Runs GraphQL operations over a shared WebSocket.
///
/// The socket opens with the first subscription and closes [idleTimeout]
/// after the last one ends. If it drops, the transport reconnects with
/// exponential backoff (up to [maxReconnectAttempts]) and restarts every
/// active subscription. The close codes `graphql-ws` uses for client errors
/// (4400, 4401, 4403, 4406, 4409, 4429) and 4500 are not retried.
///
/// With `graphql-transport-ws`, a ping that gets no reply before the next
/// one marks the connection as dead (e.g. after switching networks), which
/// triggers a reconnect.
final class WebSocketTransport implements GraphQLTransport {
  /// Creates the transport.
  WebSocketTransport(
    String url, {
    this.protocol = SubscriptionProtocol.graphqlTransportWs,
    ConnectionParamsProvider? connectionParams,
    this.connectionTimeout = const Duration(seconds: 10),
    this.keepAliveInterval = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 3),
    this.maxReconnectAttempts = 5,
    this.reconnectBaseDelay = const Duration(seconds: 1),
    WebSocketChannelFactory? channelFactory,
  })  : _uri = Uri.parse(url),
        _connectionParams = connectionParams,
        _channelFactory = channelFactory ??
            ((uri, protocols) =>
                WebSocketChannel.connect(uri, protocols: protocols));

  /// The protocol spoken by the server.
  final SubscriptionProtocol protocol;

  /// How long to wait for `connection_ack`.
  final Duration connectionTimeout;

  /// Interval between client pings (`graphql-transport-ws` only).
  final Duration keepAliveInterval;

  /// How long the socket stays open after the last subscription ends.
  final Duration idleTimeout;

  /// Reconnection attempts before active subscriptions fail. 0 disables
  /// reconnection.
  final int maxReconnectAttempts;

  /// Delay before the first reconnection; doubled for each later one.
  final Duration reconnectBaseDelay;

  static const _fatalCloseCodes = {4400, 4401, 4403, 4406, 4409, 4429, 4500};
  static const _maxReconnectDelay = Duration(seconds: 30);

  final Uri _uri;
  final ConnectionParamsProvider? _connectionParams;
  final WebSocketChannelFactory _channelFactory;
  final Map<String, _Operation> _operations = {};

  WebSocketChannel? _channel;
  // Cancelled by _closeSocket.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _socketSubscription;
  _State _state = _State.idle;
  Timer? _ackTimer;
  Timer? _keepAliveTimer;
  Timer? _idleTimer;
  Timer? _reconnectTimer;
  Timer? _stableTimer;
  int _reconnectAttempt = 0;
  bool _awaitingPong = false;
  final Random _random = Random();

  /// After this long without a drop, a connection counts as stable and the
  /// reconnect budget is restored. Resetting on `connection_ack` alone would
  /// let a server that acks and closes immediately cause endless retries.
  static const _stableAfter = Duration(seconds: 10);

  /// [_uri] without its query string, which may carry credentials.
  String get _safeUrl => '${_uri.scheme}://${_uri.authority}${_uri.path}';
  int _nextId = 0;
  int _generation = 0;
  bool _isDisposed = false;

  /// Whether the socket is open and acknowledged.
  bool get isConnected => _state == _State.connected;

  /// Number of running operations.
  int get activeOperations => _operations.length;

  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) {
    if (_isDisposed) {
      return Stream.error(_error('The WebSocket transport has been disposed'));
    }
    final id = '${++_nextId}';
    // Closed by _stop when the operation ends, fails or is cancelled.
    // ignore: close_sinks
    late final StreamController<GraphQLResponse> controller;
    controller = StreamController<GraphQLResponse>(
      onListen: () {
        _operations[id] = _Operation(request, controller);
        _idleTimer?.cancel();
        if (_state == _State.connected) {
          _start(id);
        } else if (_state == _State.idle && _reconnectTimer == null) {
          unawaited(_connect());
        }
      },
      onCancel: () => _stop(id, notifyServer: true),
    );
    return controller.stream;
  }

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final completer = Completer<GraphQLResponse>();
    // Cancelled after the first result or when cancelToken fires.
    // ignore: cancel_subscriptions
    late final StreamSubscription<GraphQLResponse> subscription;
    subscription = subscribe(request).listen(
      (response) {
        if (!completer.isCompleted) completer.complete(response);
        unawaited(subscription.cancel());
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
              _error('The operation completed without a result'));
        }
      },
    );
    unawaited(cancelToken?.whenCancelled.then((_) {
      if (completer.isCompleted) return;
      unawaited(subscription.cancel());
      completer.completeError(GraphQLException(
        GraphQLErrorKind.cancelled,
        'The request was cancelled',
        operationName: request.operationName,
      ));
    }));
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    for (final id in _operations.keys.toList()) {
      _stop(id, notifyServer: true);
    }
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    await _closeSocket();
  }

  // Connection lifecycle ----------------------------------------------------

  Future<void> _connect() async {
    _state = _State.connecting;
    final generation = ++_generation;

    final WebSocketChannel channel;
    try {
      channel = _channelFactory(_uri, [protocol.webSocketProtocol]);
      // A black-holed connection would otherwise wait forever.
      await channel.ready.timeout(connectionTimeout);
    } catch (e) {
      if (generation == _generation) {
        _onConnectionLost(_error('Could not connect to $_safeUrl: $e'));
      }
      return;
    }
    if (generation != _generation || _isDisposed) {
      unawaited(channel.sink.close());
      return;
    }

    _channel = channel;
    _socketSubscription = channel.stream.listen(
      _onMessage,
      onError: (Object e) => _onConnectionLost(_error('WebSocket error: $e')),
      onDone: () => _onConnectionLost(
        _error('WebSocket closed (code ${channel.closeCode}'
            '${channel.closeReason == null ? '' : ': ${channel.closeReason}'})'),
        closeCode: channel.closeCode,
      ),
      cancelOnError: true,
    );
    _ackTimer = Timer(connectionTimeout, () {
      _onConnectionLost(GraphQLException(
        GraphQLErrorKind.timeout,
        'No connection_ack within ${connectionTimeout.inSeconds}s',
      ));
    });

    final JsonMap params;
    try {
      params = await _connectionParams?.call() ?? const <String, dynamic>{};
    } on GraphQLException catch (e) {
      // e.g. refusing to send a token over an insecure connection: retrying
      // cannot help.
      if (generation == _generation) {
        _onConnectionLost(e, fatal: e.kind == GraphQLErrorKind.invalidRequest);
      }
      return;
    } catch (e) {
      // A transient failure (e.g. token storage); retry with backoff.
      if (generation == _generation) {
        _onConnectionLost(_error('connectionParams failed: $e'));
      }
      return;
    }
    if (generation != _generation) return;
    _send({'type': 'connection_init', 'payload': params});
  }

  void _onConnectionLost(
    GraphQLException error, {
    int? closeCode,
    bool fatal = false,
  }) {
    if (_state == _State.idle && _channel == null && _reconnectTimer == null) {
      return; // Already handled.
    }
    unawaited(_closeSocket());
    if (_operations.isEmpty || _isDisposed) return;

    final giveUp = fatal ||
        _fatalCloseCodes.contains(closeCode) ||
        _reconnectAttempt >= maxReconnectAttempts;
    if (giveUp) {
      _reconnectAttempt = 0;
      for (final id in _operations.keys.toList()) {
        _stop(id, error: error);
      }
      return;
    }

    // Jitter spreads reconnects when many clients drop at once.
    final backoff = reconnectBaseDelay * pow(2, _reconnectAttempt);
    final delay = backoff * (1 + _random.nextDouble() * 0.25);
    _reconnectAttempt++;
    _reconnectTimer = Timer(
      delay > _maxReconnectDelay ? _maxReconnectDelay : delay,
      () {
        _reconnectTimer = null;
        if (_operations.isEmpty || _isDisposed) {
          _reconnectAttempt = 0;
          return;
        }
        unawaited(_connect());
      },
    );
  }

  Future<void> _closeSocket() async {
    _generation++;
    _state = _State.idle;
    _awaitingPong = false;
    _ackTimer?.cancel();
    _stableTimer?.cancel();
    _keepAliveTimer?.cancel();
    final subscription = _socketSubscription;
    final channel = _channel;
    _socketSubscription = null;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
  }

  // Messages ----------------------------------------------------------------

  void _onMessage(dynamic raw) {
    _awaitingPong = false; // Any message proves the connection is alive.
    final JsonMap message;
    try {
      message = jsonDecode(raw as String) as JsonMap;
    } catch (_) {
      _onConnectionLost(_error('Malformed message from server'), fatal: true);
      return;
    }

    final id = message['id'] as String?;
    switch (message['type']) {
      case 'connection_ack':
        _ackTimer?.cancel();
        _state = _State.connected;
        _stableTimer?.cancel();
        _stableTimer = Timer(_stableAfter, () => _reconnectAttempt = 0);
        _startKeepAlive();
        _operations.keys.toList().forEach(_start);
      case 'connection_error':
        _onConnectionLost(
          _error('Server rejected the connection: ${message['payload']}'),
          fatal: true,
        );
      case 'ping':
        _send({
          'type': 'pong',
          if (message['payload'] != null) 'payload': message['payload'],
        });
      case 'pong' || 'ka':
        break;
      case 'next' || 'data':
        final operation = _operations[id];
        if (operation == null) return;
        try {
          operation.controller
              .add(GraphQLResponse.fromJson(message['payload']));
        } on GraphQLException catch (e) {
          operation.controller.addError(e);
        }
      case 'error':
        if (id != null) {
          _stop(id, error: _operationError(id, message['payload']));
        }
      case 'complete':
        if (id != null) _stop(id);
    }
  }

  void _start(String id) {
    final operation = _operations[id];
    if (operation == null) return;
    _send({
      'id': id,
      'type': protocol.subscribe,
      'payload': operation.request.toJson(),
    });
  }

  void _stop(String id, {GraphQLException? error, bool notifyServer = false}) {
    final operation = _operations.remove(id);
    if (operation == null) return;
    if (notifyServer && _state == _State.connected) {
      _send({'id': id, 'type': protocol.stop});
    }
    if (error != null) {
      operation.controller.addError(
        error.withOperationName(operation.request.operationName),
      );
    }
    unawaited(operation.controller.close());

    if (_operations.isEmpty && _state != _State.idle) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleTimeout, () {
        if (_operations.isEmpty) unawaited(_closeSocket());
      });
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    if (!protocol.clientPings) return;
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      if (_state != _State.connected) return;
      if (_awaitingPong) {
        _onConnectionLost(GraphQLException(
          GraphQLErrorKind.timeout,
          'No reply to ping within ${keepAliveInterval.inSeconds}s',
        ));
        return;
      }
      _awaitingPong = true;
      _send({'type': 'ping'});
    });
  }

  void _send(JsonMap message) => _channel?.sink.add(jsonEncode(message));

  GraphQLException _operationError(String id, Object? payload) {
    final errors = switch (payload) {
      final List<dynamic> list =>
        list.whereType<JsonMap>().map(GraphQLError.fromJson).toList(),
      final JsonMap map when map['message'] is String => [
          GraphQLError.fromJson(map)
        ],
      _ => <GraphQLError>[],
    };
    return GraphQLException.fromErrors(
      errors,
      operationName: _operations[id]?.request.operationName,
    );
  }

  static GraphQLException _error(String message) =>
      GraphQLException(GraphQLErrorKind.network, message);
}

final class _Operation {
  _Operation(this.request, this.controller);

  final GraphQLRequest request;
  final StreamController<GraphQLResponse> controller;
}
