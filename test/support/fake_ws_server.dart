import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A local GraphQL WebSocket server for transport tests.
///
/// Acknowledges `connection_init` and answers each started operation with
/// [events] then `complete` (unless [completeAfterEvents] is false), or with
/// [errorPayload] when set.
class FakeWsServer {
  FakeWsServer._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = [];

  /// Every client message, decoded, across all connections.
  final List<Map<String, dynamic>> received = [];

  /// Sub-protocols requested, one entry per connection.
  final List<List<String>> requestedProtocols = [];

  /// `connection_init` payloads, one per connection.
  final List<Object?> initPayloads = [];

  List<Map<String, dynamic>> events = [];
  Duration firstEventDelay = Duration.zero;
  bool completeAfterEvents = true;
  Object? errorPayload;

  /// Close code to use when rejecting `connection_init`, if any.
  int? rejectInitWithCode;

  /// Whether to answer client pings (false simulates a dead connection).
  bool answerPings = true;

  String get url => 'ws://${_server.address.host}:${_server.port}/graphql';

  int get connectionCount => requestedProtocols.length;

  static Future<FakeWsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeWsServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> _handle(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) {
        requestedProtocols.add(protocols);
        return protocols.first;
      },
    );
    _sockets.add(socket);
    final legacy = socket.protocol == 'graphql-ws';

    socket.listen((raw) async {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      received.add(message);
      switch (message['type']) {
        case 'connection_init':
          initPayloads.add(message['payload']);
          final code = rejectInitWithCode;
          if (code != null) {
            await socket.close(code, 'rejected');
            return;
          }
          socket.add(jsonEncode({'type': 'connection_ack'}));
        case 'ping':
          if (answerPings) socket.add(jsonEncode({'type': 'pong'}));
        case 'subscribe' || 'start':
          final id = message['id'];
          if (errorPayload != null) {
            socket.add(jsonEncode(
                {'id': id, 'type': 'error', 'payload': errorPayload}));
            return;
          }
          await Future<void>.delayed(firstEventDelay);
          for (final event in events) {
            socket.add(jsonEncode({
              'id': id,
              'type': legacy ? 'data' : 'next',
              'payload': {'data': event},
            }));
          }
          if (completeAfterEvents) {
            socket.add(jsonEncode({'id': id, 'type': 'complete'}));
          }
      }
    });
  }

  /// Sends a `next` event for [id] on every open socket.
  void push(String id, Map<String, dynamic> data) {
    for (final socket in _sockets) {
      socket.add(jsonEncode({
        'id': id,
        'type': 'next',
        'payload': {'data': data},
      }));
    }
  }

  /// Drops every open connection with [code].
  Future<void> dropConnections([int code = 1011]) async {
    final sockets = List.of(_sockets);
    _sockets.clear();
    for (final socket in sockets) {
      await socket.close(code, 'dropped');
    }
  }

  /// Waits until [count] messages of [type] were received.
  Future<List<Map<String, dynamic>>> waitFor(String type,
      {int count = 1}) async {
    for (var i = 0; i < 500; i++) {
      final matches = received.where((m) => m['type'] == type).toList();
      if (matches.length >= count) return matches;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('Expected $count "$type" message(s)');
  }

  Future<void> close() async {
    await dropConnections(1000);
    await _server.close(force: true);
  }
}
