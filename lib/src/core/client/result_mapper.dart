import '../json.dart';
import '../request/graphql_request.dart';
import '../request/policies.dart';
import '../response/graphql_error.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';
import '../response/graphql_result.dart';

/// Converts the `data` object of a response into an app type.
typedef DataParser<T> = T Function(JsonMap data);

/// Turns raw responses into [GraphQLResult]s.
abstract final class ResultMapper {
  /// Whether [response]'s data may be written to the cache under
  /// [errorPolicy].
  static bool isCacheable(GraphQLResponse response, ErrorPolicy errorPolicy) =>
      response.data != null &&
      (!response.hasErrors || errorPolicy != ErrorPolicy.none);

  /// Applies [errorPolicy] and [parse] to [response].
  static GraphQLResult<T> fromResponse<T>(
    GraphQLResponse response,
    GraphQLRequest request, {
    required ErrorPolicy errorPolicy,
    DataParser<T>? parse,
    ResultSource source = ResultSource.network,
  }) {
    final data = response.data;
    if (data == null ||
        (response.hasErrors && errorPolicy == ErrorPolicy.none)) {
      return GraphQLFailure(GraphQLException.fromErrors(
        response.errors,
        statusCode: response.statusCode,
        operationName: request.operationName,
      ));
    }
    return fromData(
      data,
      request,
      parse: parse,
      source: source,
      errors: errorPolicy == ErrorPolicy.all ? response.errors : const [],
      extensions: response.extensions,
    );
  }

  /// Wraps [data] in a [GraphQLSuccess], or a [GraphQLFailure] of kind
  /// [GraphQLErrorKind.invalidResponse] when [parse] throws.
  static GraphQLResult<T> fromData<T>(
    JsonMap data,
    GraphQLRequest request, {
    DataParser<T>? parse,
    ResultSource source = ResultSource.network,
    List<GraphQLError> errors = const [],
    JsonMap? extensions,
  }) {
    try {
      return GraphQLSuccess(
        parse == null ? _cast<T>(data) : parse(data),
        errors: errors,
        source: source,
        extensions: extensions,
      );
    } on GraphQLException catch (e) {
      return GraphQLFailure(e.withOperationName(request.operationName));
    } catch (e, stackTrace) {
      return GraphQLFailure(GraphQLException(
        GraphQLErrorKind.invalidResponse,
        'parse failed for ${request.operationName ?? 'operation'}: $e',
        operationName: request.operationName,
        cause: e,
        stackTrace: stackTrace,
      ));
    }
  }

  /// Applies [parse], or returns [data] itself when it already is a [T].
  ///
  /// Throws a [GraphQLException] explaining how to fix a missing [parse].
  static T parseOrCast<T>(JsonMap data, DataParser<T>? parse) =>
      parse == null ? _cast<T>(data) : parse(data);

  static T _cast<T>(JsonMap data) {
    if (data is T) return data as T;
    throw GraphQLException(
      GraphQLErrorKind.invalidResponse,
      'The result data is a JSON map, not $T. Pass parse: to convert it, '
      'e.g. parse: (data) => User.fromJson(data["user"]).',
    );
  }

  /// Wraps unexpected errors in a [GraphQLException].
  static GraphQLException toException(
    Object error,
    StackTrace stackTrace,
    GraphQLRequest request,
  ) =>
      error is GraphQLException
          ? error.withOperationName(request.operationName)
          : GraphQLException(
              GraphQLErrorKind.unknown,
              error.toString(),
              operationName: request.operationName,
              cause: error,
              stackTrace: stackTrace,
            );
}
