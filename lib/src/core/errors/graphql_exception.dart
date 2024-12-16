import '../../../graphql_client_flutter.dart';

/// Custom exception class for GraphQL-related errors
class GraphQLException implements Exception {
  /// Main error message
  final String message;

  /// List of specific GraphQL errors returned by the server
  final List<GraphQLError>? errors;

  /// Original exception that caused this error
  final Exception? originalException;

  /// HTTP status code if applicable
  final int? statusCode;

  /// Additional error context/metadata
  final Map<String, dynamic>? extensions;

  /// Request operation type (query/mutation/subscription)
  final String? operationType;

  /// Operation name if available
  final String? operationName;

  GraphQLException({
    required this.message,
    this.errors,
    this.originalException,
    this.statusCode,
    this.extensions,
    this.operationType,
    this.operationName,
  });

  /// Creates an exception for network errors
  factory GraphQLException.network(String message, {Exception? originalException}) {
    return GraphQLException(
      message: 'Network Error: $message',
      originalException: originalException,
      extensions: {'type': 'network_error'},
    );
  }

  /// Creates an exception for parser errors
  factory GraphQLException.parseError(String message) {
    return GraphQLException(
      message: 'Parse Error: $message',
      extensions: {'type': 'parse_error'},
    );
  }

  /// Creates an exception for validation errors
  factory GraphQLException.validation(String message, List<GraphQLError> errors) {
    return GraphQLException(
      message: 'Validation Error: $message',
      errors: errors,
      extensions: {'type': 'validation_error'},
    );
  }

  /// Creates an exception for cache errors
  factory GraphQLException.cache(String message) {
    return GraphQLException(
      message: 'Cache Error: $message',
      extensions: {'type': 'cache_error'},
    );
  }

  /// Whether this exception represents a network error
  bool get isNetworkError => 
      extensions?['type'] == 'network_error' || 
      originalException.toString().contains('NetworkError');

  /// Whether this exception represents a validation error
  bool get isValidationError => 
      extensions?['type'] == 'validation_error' || 
      (errors?.any((e) => e.extensions?['code'] == 'GRAPHQL_VALIDATION_FAILED') ?? false);

  /// Whether this exception represents a parse error
  bool get isParseError => extensions?['type'] == 'parse_error';

  /// Whether this exception represents a cache error
  bool get isCacheError => extensions?['type'] == 'cache_error';

  /// Gets all error messages including nested GraphQL errors
  List<String> get allMessages {
    final messages = <String>[message];
    if (errors != null) {
      messages.addAll(errors!.map((e) => e.message));
    }
    return messages;
  }

  /// Gets a formatted error message for logging or display
  String getFormattedMessage({bool includeStackTrace = false}) {
    final buffer = StringBuffer();
    buffer.writeln('GraphQLException: $message');

    if (errors?.isNotEmpty ?? false) {
      buffer.writeln('GraphQL Errors:');
      for (final error in errors!) {
        buffer.writeln('  - ${error.message}');
        if (error.path != null) {
          buffer.writeln('    Path: ${error.path!.join('.')}');
        }
        if (error.locations != null) {
          for (final location in error.locations!) {
            buffer.writeln('    Location: line ${location.line}, column ${location.column}');
          }
        }
      }
    }

    if (statusCode != null) {
      buffer.writeln('Status Code: $statusCode');
    }

    if (operationType != null) {
      buffer.writeln('Operation Type: $operationType');
    }

    if (operationName != null) {
      buffer.writeln('Operation Name: $operationName');
    }

    if (includeStackTrace && originalException != null) {
      buffer.writeln('Original Exception:');
      buffer.writeln(originalException.toString());
    }

    return buffer.toString();
  }

  /// Creates a map representation of the exception
  Map<String, dynamic> toMap() {
    return {
      'message': message,
      'errors': errors?.map((e) => {
        'message': e.message,
        'locations': e.locations?.map((l) => {
          'line': l.line,
          'column': l.column,
        }).toList(),
        'path': e.path,
        'extensions': e.extensions,
      }).toList(),
      'statusCode': statusCode,
      'extensions': extensions,
      'operationType': operationType,
      'operationName': operationName,
    };
  }

  @override
  String toString() => getFormattedMessage();
}