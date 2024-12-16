import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/errors/graphql_exception.dart';
import '../../domain/entities/graphql_error.dart';
import '../../domain/entities/graphql_response.dart';

/// Repository for handling GraphQL subscriptions over WebSocket
class GraphQLSubscriptionRepository {
  final String _url;
  late WebSocketChannel _channel;
  final Duration _connectionTimeout;
  final Duration _keepAliveInterval;
  final Map<String, String>? _connectionParams;
  
  bool _isConnected = false;
  Timer? _keepAliveTimer;
  final Map<String, StreamController<GraphQLResponse<dynamic>>> _subscriptions = {};
  
  GraphQLSubscriptionRepository(
    this._url, {
    Duration connectionTimeout = const Duration(seconds: 10),
    Duration keepAliveInterval = const Duration(seconds: 30),
    Map<String, String>? connectionParams,
  }) : _connectionTimeout = connectionTimeout,
       _keepAliveInterval = keepAliveInterval,
       _connectionParams = connectionParams {
    _initializeConnection();
  }

  Future<void> _initializeConnection() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url));
      
      // Set up connection timeout
      final connectionCompleter = Completer<void>();
      late StreamSubscription messageSubscription;
      
      final timeoutTimer = Timer(_connectionTimeout, () {
        messageSubscription.cancel();
        connectionCompleter.completeError(
          GraphQLException(
            message: 'WebSocket connection timeout',
            extensions: {'type': 'connection_timeout'},
          ),
        );
      });

      messageSubscription = _channel.stream.listen(
        (message) {
          final decodedMessage = jsonDecode(message);
          if (decodedMessage['type'] == 'connection_ack') {
            _isConnected = true;
            connectionCompleter.complete();
            _startKeepAlive();
          }
        },
        onError: (error) {
          connectionCompleter.completeError(
            GraphQLException(
              message: 'WebSocket connection error: $error',
              extensions: {'type': 'connection_error'},
            ),
          );
        },
      );

      // Send connection initialization
      final initPayload = {
        'type': 'connection_init',
        'payload': _connectionParams ?? {},
      };
      _channel.sink.add(jsonEncode(initPayload));

      await connectionCompleter.future;
      timeoutTimer.cancel();
      
      // Set up message handling after connection
      _handleMessages();
    } catch (e) {
      throw GraphQLException(
        message: 'Failed to initialize WebSocket connection: $e',
        extensions: {'type': 'initialization_error'},
      );
    }
  }

  void _handleMessages() {
    _channel.stream.listen(
      (message) {
        final decodedMessage = jsonDecode(message);
        final String? id = decodedMessage['id'];
        
        if (id != null && _subscriptions.containsKey(id)) {
          _handleSubscriptionMessage(id, decodedMessage);
        }
      },
      onError: (error) {
        _handleConnectionError(error);
      },
      onDone: () {
        _handleConnectionClosed();
      },
    );
  }

  void _handleSubscriptionMessage(String id, Map<String, dynamic> message) {
    final controller = _subscriptions[id];
    if (controller == null) return;

    switch (message['type']) {
      case 'data':
        final data = message['payload']['data'];
        final errors = message['payload']['errors'] != null
            ? (message['payload']['errors'] as List)
                .map((e) => GraphQLError.fromJson(e))
                .toList()
            : null;
            
        controller.add(GraphQLResponse<dynamic>(
          data: data,
          errors: errors,
        ));
        break;
        
      case 'error':
        controller.addError(GraphQLException(
          message: 'Subscription error',
          errors: [
            GraphQLError(message: message['payload']['message']),
          ],
        ));
        break;
        
      case 'complete':
        controller.close();
        _subscriptions.remove(id);
        break;
    }
  }

  Stream<GraphQLResponse<T>> subscribe<T>(
    String query, {
    Map<String, dynamic>? variables,
    Duration? timeout,
  }) {
    if (!_isConnected) {
      throw GraphQLException(
        message: 'WebSocket not connected',
        extensions: {'type': 'not_connected'},
      );
    }

    final id = _generateSubscriptionId();
    final controller = StreamController<GraphQLResponse<T>>();
    _subscriptions[id] = controller as StreamController<GraphQLResponse<dynamic>>;

    final payload = {
      'type': 'start',
      'id': id,
      'payload': {
        'query': query,
        'variables': variables,
      },
    };

    _channel.sink.add(jsonEncode(payload));

    // Set up timeout if specified
    if (timeout != null) {
      Timer(timeout, () {
        if (_subscriptions.containsKey(id)) {
          controller.addError(GraphQLException(
            message: 'Subscription timeout',
            extensions: {'type': 'timeout'},
          ));
          _unsubscribe(id);
        }
      });
    }

    return controller.stream;
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (timer) {
      if (_isConnected) {
        _channel.sink.add(jsonEncode({'type': 'ka'}));
      }
    });
  }

  Future<void> _unsubscribe(String id) async {
    if (!_subscriptions.containsKey(id)) return;

    _channel.sink.add(jsonEncode({
      'type': 'stop',
      'id': id,
    }));

    await _subscriptions[id]?.close();
    _subscriptions.remove(id);
  }

  void _handleConnectionError(dynamic error) {
    final exception = GraphQLException(
      message: 'WebSocket error: $error',
      extensions: {'type': 'websocket_error'},
    );
    
    for (final controller in _subscriptions.values) {
      controller.addError(exception);
    }
  }

  void _handleConnectionClosed() {
    _isConnected = false;
    _keepAliveTimer?.cancel();
    
    for (final controller in _subscriptions.values) {
      controller.close();
    }
    _subscriptions.clear();
  }

  String _generateSubscriptionId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  Future<void> dispose() async {
    _keepAliveTimer?.cancel();
    
    // Unsubscribe from all active subscriptions
    for (final id in _subscriptions.keys.toList()) {
      await _unsubscribe(id);
    }
    
    await _channel.sink.close();
    _isConnected = false;
  }

  bool get isConnected => _isConnected;
  
  int get activeSubscriptions => _subscriptions.length;
}