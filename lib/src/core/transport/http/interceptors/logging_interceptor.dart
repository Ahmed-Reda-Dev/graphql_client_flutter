import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';

import 'dio_aware_interceptor.dart';

/// Logs GraphQL requests and responses.
///
/// Credentials are redacted from logged headers. Bodies and URL query
/// strings (which may contain personal data, e.g. GET variables) are only
/// logged when [logBodies] is true.
final class LoggingInterceptor extends Interceptor {
  /// Creates the interceptor.
  LoggingInterceptor({
    void Function(String message)? logger,
    this.logBodies = false,
    this.logHeaders = false,
    Set<String> redactHeaders = const {},
  })  : _logger = logger ?? _defaultLogger,
        _redacted = {
          ..._sensitiveHeaders,
          ...redactHeaders.map((h) => h.toLowerCase()),
        };

  /// Whether to include request variables and response data.
  final bool logBodies;

  /// Whether to include (redacted) request headers.
  final bool logHeaders;

  final void Function(String message) _logger;
  final Set<String> _redacted;

  static const _sensitiveHeaders = {
    'authorization',
    'cookie',
    'set-cookie',
    'proxy-authorization',
    'x-api-key',
    'api-key',
    'apikey',
    'x-auth-token',
    'x-access-token',
    'x-csrf-token',
  };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[RequestExtras.startedAt] =
        DateTime.now().microsecondsSinceEpoch;
    final uri = logBodies
        ? '${options.uri}'
        : '${options.uri.origin}${options.uri.path}';
    final lines = ['→ ${_label(options)} ${options.method} $uri'];
    if (logHeaders) lines.add('  headers: ${_redact(options.headers)}');
    if (logBodies && options.data is Map) {
      lines.add(
          '  variables: ${jsonEncode((options.data as Map)['variables'])}');
    }
    _logger(lines.join('\n'));
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    final body = response.data;
    final errors = _errorCount(body);
    final lines = [
      '← ${_label(options)} ${response.statusCode} in ${_elapsed(options)}'
          '${errors > 0 ? ' with $errors error(s)' : ''}',
    ];
    if (logBodies) lines.add('  body: ${_truncate(jsonEncode(body))}');
    _logger(lines.join('\n'));
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    final status = err.response?.statusCode;
    _logger('✕ ${_label(options)} ${err.type.name}'
        '${status != null ? ' $status' : ''} in ${_elapsed(options)}: '
        '${err.message ?? err.error}');
    handler.next(err);
  }

  Map<String, Object?> _redact(Map<String, Object?> headers) => {
        for (final MapEntry(:key, :value) in headers.entries)
          key: _redacted.contains(key.toLowerCase()) ? '***' : value,
      };

  /// Errors in a response body, or across every body of a batch.
  static int _errorCount(Object? body) => switch (body) {
        final List<dynamic> batch =>
          batch.fold(0, (n, b) => n + _errorCount(b)),
        final Map<dynamic, dynamic> map when map['errors'] is List =>
          (map['errors'] as List).length,
        _ => 0,
      };

  static String _label(RequestOptions options) {
    final type = options.extra[RequestExtras.operationType] ?? 'request';
    final name = options.extra[RequestExtras.operationName];
    return name == null ? '$type' : '$type $name';
  }

  static String _elapsed(RequestOptions options) {
    final start = options.extra[RequestExtras.startedAt];
    if (start is! int) return '?';
    final micros = DateTime.now().microsecondsSinceEpoch - start;
    return '${(micros / 1000).toStringAsFixed(0)}ms';
  }

  static String _truncate(String text, [int max = 2000]) => text.length <= max
      ? text
      : '${text.substring(0, max)}… (${text.length} chars)';

  static void _defaultLogger(String message) =>
      developer.log(message, name: 'graphql');
}
