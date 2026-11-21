import 'graphql_error.dart';

/// What went wrong, in terms an app can act on.
enum GraphQLErrorKind {
  /// The server could not be reached (offline, DNS, refused connection).
  network,

  /// The request took longer than the configured timeout.
  timeout,

  /// The request was cancelled by the caller.
  cancelled,

  /// Missing or expired credentials (HTTP 401 or code `UNAUTHENTICATED`).
  unauthenticated,

  /// Valid credentials without permission (HTTP 403 or code `FORBIDDEN`).
  forbidden,

  /// The document or variables were rejected (syntax, validation, input).
  invalidRequest,

  /// The server failed (HTTP 5xx or code `INTERNAL_SERVER_ERROR`).
  server,

  /// The server executed the operation and returned other errors.
  graphql,

  /// The response could not be decoded, or `parse` threw.
  invalidResponse,

  /// `FetchPolicy.cacheOnly` found no complete data in the cache.
  cacheMiss,

  /// Anything else.
  unknown;

  /// Whether retrying the same request may succeed.
  bool get isTransient => switch (this) {
        network || timeout || server => true,
        _ => false,
      };
}

/// The single exception type surfaced by this package.
///
/// Inspect [kind] to decide what to do, and [errors] for the server's
/// GraphQL errors when there are any.
final class GraphQLException implements Exception {
  /// Creates an exception.
  const GraphQLException(
    this.kind,
    this.message, {
    this.errors = const [],
    this.statusCode,
    this.operationName,
    this.cause,
    this.stackTrace,
  });

  /// Builds an exception from GraphQL errors and an optional HTTP status,
  /// deriving [kind] from the status and the errors' `extensions.code`.
  factory GraphQLException.fromErrors(
    List<GraphQLError> errors, {
    int? statusCode,
    String? operationName,
  }) {
    return GraphQLException(
      kindFor(statusCode: statusCode, errors: errors),
      errors.isEmpty
          ? 'Request failed with HTTP $statusCode'
          : errors.map((e) => e.message).join('; '),
      errors: errors,
      statusCode: statusCode,
      operationName: operationName,
    );
  }

  /// The category of failure.
  final GraphQLErrorKind kind;

  /// Developer-facing description. Use [userMessage] for UI text.
  final String message;

  /// Errors returned by the server, if any.
  final List<GraphQLError> errors;

  /// HTTP status code, when the failure came from an HTTP response.
  final int? statusCode;

  /// Name of the operation that failed.
  final String? operationName;

  /// The underlying error, e.g. a `DioException` or a `FormatException`.
  final Object? cause;

  /// Where [cause] was thrown, when known.
  final StackTrace? stackTrace;

  /// A short, non-technical message suitable for showing to end users.
  String get userMessage => switch (kind) {
        GraphQLErrorKind.network =>
          'No connection. Check your internet and try again.',
        GraphQLErrorKind.timeout => 'The server took too long to respond.',
        GraphQLErrorKind.cancelled => 'The request was cancelled.',
        GraphQLErrorKind.unauthenticated => 'Please sign in again.',
        GraphQLErrorKind.forbidden => "You don't have permission to do that.",
        GraphQLErrorKind.invalidRequest =>
          'The request was invalid. Please check your input.',
        GraphQLErrorKind.server ||
        GraphQLErrorKind.invalidResponse =>
          'Something went wrong on our side. Please try again.',
        GraphQLErrorKind.cacheMiss => 'This content is not available offline.',
        GraphQLErrorKind.graphql ||
        GraphQLErrorKind.unknown =>
          'Something went wrong. Please try again.',
      };

  /// Returns a copy with [operationName] set, unless one is already present.
  GraphQLException withOperationName(String? name) {
    if (operationName != null || name == null) return this;
    return GraphQLException(
      kind,
      message,
      errors: errors,
      statusCode: statusCode,
      operationName: name,
      cause: cause,
      stackTrace: stackTrace,
    );
  }

  /// Derives a [GraphQLErrorKind] from an HTTP status and GraphQL errors.
  ///
  /// Error codes take precedence over the status, because many servers
  /// answer every request with HTTP 200.
  static GraphQLErrorKind kindFor({
    int? statusCode,
    List<GraphQLError> errors = const [],
  }) {
    for (final error in errors) {
      final kind = switch (error.code) {
        'UNAUTHENTICATED' => GraphQLErrorKind.unauthenticated,
        'FORBIDDEN' => GraphQLErrorKind.forbidden,
        'GRAPHQL_PARSE_FAILED' ||
        'GRAPHQL_VALIDATION_FAILED' ||
        'BAD_USER_INPUT' ||
        'BAD_REQUEST' ||
        'PERSISTED_QUERY_NOT_SUPPORTED' =>
          GraphQLErrorKind.invalidRequest,
        'INTERNAL_SERVER_ERROR' => GraphQLErrorKind.server,
        _ => null,
      };
      if (kind != null) return kind;
    }
    return switch (statusCode) {
      401 => GraphQLErrorKind.unauthenticated,
      403 => GraphQLErrorKind.forbidden,
      final int s when s >= 400 && s < 500 => GraphQLErrorKind.invalidRequest,
      final int s when s >= 500 => GraphQLErrorKind.server,
      _ when errors.isNotEmpty => GraphQLErrorKind.graphql,
      _ => GraphQLErrorKind.unknown,
    };
  }

  @override
  String toString() {
    final buffer = StringBuffer('GraphQLException(${kind.name}');
    if (operationName != null) buffer.write(', operation: $operationName');
    if (statusCode != null) buffer.write(', status: $statusCode');
    buffer.write('): $message');
    // Only the cause's type: its text can include request URLs, variables
    // or response bodies. Inspect [cause] directly when debugging.
    if (cause != null) buffer.write(' (caused by ${cause.runtimeType})');
    return buffer.toString();
  }
}
