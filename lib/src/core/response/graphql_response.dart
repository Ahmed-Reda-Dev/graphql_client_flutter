import 'package:meta/meta.dart';

import '../json.dart';
import 'graphql_error.dart';
import 'graphql_exception.dart';

/// A raw GraphQL response as received from a transport.
///
/// Transports return this for every response with a GraphQL body, including
/// error responses. The client turns it into a `GraphQLResult`.
@immutable
final class GraphQLResponse {
  /// Creates a response.
  const GraphQLResponse({
    this.data,
    this.errors = const [],
    this.extensions,
    this.statusCode,
  });

  /// Parses a response body.
  ///
  /// Throws a [GraphQLException] of kind [GraphQLErrorKind.invalidResponse]
  /// if [body] is not a GraphQL response object.
  factory GraphQLResponse.fromJson(Object? body, {int? statusCode}) {
    if (body is! JsonMap ||
        !(body.containsKey('data') || body.containsKey('errors'))) {
      throw GraphQLException(
        GraphQLErrorKind.invalidResponse,
        'Expected a GraphQL response with "data" or "errors", '
        'got ${_describe(body)}',
        statusCode: statusCode,
      );
    }
    final data = body['data'];
    final errors = body['errors'];
    final extensions = body['extensions'];
    return GraphQLResponse(
      data: data is JsonMap ? data : null,
      errors: errors is List
          ? errors.whereType<JsonMap>().map(GraphQLError.fromJson).toList()
          : const [],
      extensions: extensions is JsonMap ? extensions : null,
      statusCode: statusCode,
    );
  }

  /// The `data` object, or null if execution did not produce data.
  final JsonMap? data;

  /// The `errors` array.
  final List<GraphQLError> errors;

  /// The `extensions` object.
  final JsonMap? extensions;

  /// HTTP status, when the response came over HTTP.
  final int? statusCode;

  /// Whether the server reported any errors.
  bool get hasErrors => errors.isNotEmpty;

  static String _describe(Object? body) => switch (body) {
        null => 'an empty body',
        final String s when s.length > 80 => 'text "${s.substring(0, 80)}..."',
        final String s => 'text "$s"',
        _ => body.runtimeType.toString(),
      };
}
