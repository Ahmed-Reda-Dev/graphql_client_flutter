import 'package:dio/dio.dart';

import '../../../graphql_client_flutter.dart';

/// Interceptor for logging GraphQL requests and responses
class LoggingInterceptor extends Interceptor {
  /// Determines what to log
  final LoggingOptions options;

  /// Optional custom logger function
  final void Function(String)? logger;

  /// Optional custom error logger function
  final void Function(String)? errorLogger;

  /// Whether to log request headers
  final bool logHeaders;

  /// Whether to log request variables
  final bool logVariables;

  /// Whether to log response data
  final bool logResponseData;

  /// Whether to pretty print JSON
  final bool prettyPrintJson;

  LoggingInterceptor({
    this.options = const LoggingOptions(),
    this.logger,
    this.errorLogger,
    this.logHeaders = true,
    this.logVariables = true,
    this.logResponseData = true,
    this.prettyPrintJson = true,
  });

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (this.options.logRequests) {
      _log('GraphQL Request:', [
        'Operation: ${_getOperationDetails(options)}',
        if (logHeaders) 'Headers: ${options.headers}',
        if (logVariables)
          'Variables: ${_formatJson(options.data?['variables'])}',
        'Query: ${_formatQuery(options.data?['query'])}',
      ]);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (options.logResponses) {
      try {
        final parsedResponse = ResponseParser.parse(response.data);
        _log('GraphQL Response:', [
          'Operation: ${_getOperationDetails(response.requestOptions)}',
          'Status: ${response.statusCode}',
          if (logResponseData) 'Data: ${_formatJson(parsedResponse.data)}',
          if (parsedResponse.errors?.isNotEmpty ?? false)
            'Errors: ${_formatJson(parsedResponse.errors)}',
        ]);
      } catch (e) {
        _logError('Failed to parse response', [e.toString()]);
      }
    }
    handler.next(response);
  }

  @override
  void onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    if (options.logErrors) {
      _logError('GraphQL Error:', [
        'Operation: ${_getOperationDetails(err.requestOptions)}',
        'Error: ${err.message}',
        if (err.response != null) 'Status: ${err.response?.statusCode}',
        if (err.response?.data != null)
          'Data: ${_formatJson(err.response?.data)}',
      ]);
    }
    handler.next(err);
  }

  String _getOperationDetails(RequestOptions options) {
    final data = options.data as Map<String, dynamic>?;
    final query = data?['query'] as String?;
    final operationType = QueryTransformer.getOperationType(query ?? '');
    final operationName = data?['operationName'] as String? ??
        QueryTransformer.getOperationName(query ?? '');

    return '${operationType ?? 'Unknown'}'
        '${operationName != null ? ' ($operationName)' : ''}';
  }

  String _formatQuery(String? query) {
    if (query == null) return 'null';
    if (!prettyPrintJson) return query;
    return QueryTransformer.prettyPrint(query);
  }

  String _formatJson(dynamic data) {
    if (data == null) return 'null';
    if (!prettyPrintJson) return data.toString();

    const jsonIndent = '  ';
    final buffer = StringBuffer();
    var indent = 0;

    data.toString().split('').forEach((char) {
      if (char == '{' || char == '[') {
        buffer.write(char);
        buffer.write('\n');
        indent++;
        buffer.write(jsonIndent * indent);
      } else if (char == '}' || char == ']') {
        buffer.write('\n');
        indent--;
        buffer.write(jsonIndent * indent);
        buffer.write(char);
      } else if (char == ',') {
        buffer.write(char);
        buffer.write('\n');
        buffer.write(jsonIndent * indent);
      } else {
        buffer.write(char);
      }
    });

    return buffer.toString();
  }

  void _log(String title, List<String> messages) {
    final log = [title, ...messages.map((m) => '  $m')].join('\n');
    if (logger != null) {
      logger!(log);
    } else {
      print(log);
    }
  }

  void _logError(String title, List<String> messages) {
    final log = [title, ...messages.map((m) => '  $m')].join('\n');
    if (errorLogger != null) {
      errorLogger!(log);
    } else {
      print('\x1B[31m$log\x1B[0m'); // Red color for errors
    }
  }
}

/// Configuration options for logging
class LoggingOptions {
  /// Whether to log requests
  final bool logRequests;

  /// Whether to log responses
  final bool logResponses;

  /// Whether to log errors
  final bool logErrors;

  const LoggingOptions({
    this.logRequests = true,
    this.logResponses = true,
    this.logErrors = true,
  });
}
