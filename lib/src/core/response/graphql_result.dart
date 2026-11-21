import '../json.dart';
import 'graphql_error.dart';
import 'graphql_exception.dart';

/// Where a result's data came from.
enum ResultSource {
  /// Fetched from the server.
  network,

  /// Read from the cache.
  cache,

  /// Produced by an optimistic response that the server has not confirmed.
  optimistic,
}

/// The outcome of a GraphQL operation: either [GraphQLSuccess] or
/// [GraphQLFailure].
///
/// Use an exhaustive `switch`:
///
/// ```dart
/// switch (await client.query(getUser, parse: User.fromJson)) {
///   case GraphQLSuccess(:final data):
///     print(data.name);
///   case GraphQLFailure(:final exception):
///     print(exception.userMessage);
/// }
/// ```
sealed class GraphQLResult<T> {
  const GraphQLResult();

  /// Whether this is a [GraphQLSuccess].
  bool get isSuccess => this is GraphQLSuccess<T>;

  /// The data on success, otherwise null.
  T? get dataOrNull => switch (this) {
        GraphQLSuccess(:final data) => data,
        GraphQLFailure() => null,
      };

  /// The exception on failure, otherwise null.
  GraphQLException? get exceptionOrNull => switch (this) {
        GraphQLSuccess() => null,
        GraphQLFailure(:final exception) => exception,
      };

  /// The data on success; throws the [GraphQLException] on failure.
  T get dataOrThrow => switch (this) {
        GraphQLSuccess(:final data) => data,
        GraphQLFailure(:final exception) => throw exception,
      };

  /// Transforms the data of a success, keeping failures as they are.
  GraphQLResult<R> map<R>(R Function(T data) transform) => switch (this) {
        GraphQLSuccess(
          :final data,
          :final errors,
          :final source,
          :final extensions
        ) =>
          GraphQLSuccess(
            transform(data),
            errors: errors,
            source: source,
            extensions: extensions,
          ),
        GraphQLFailure(:final exception) => GraphQLFailure(exception),
      };

  /// Calls [success] or [failure] and returns its result.
  R when<R>({
    required R Function(T data) success,
    required R Function(GraphQLException exception) failure,
  }) =>
      switch (this) {
        GraphQLSuccess(:final data) => success(data),
        GraphQLFailure(:final exception) => failure(exception),
      };
}

/// A successful operation.
final class GraphQLSuccess<T> extends GraphQLResult<T> {
  /// Creates a success.
  const GraphQLSuccess(
    this.data, {
    this.errors = const [],
    this.source = ResultSource.network,
    this.extensions,
  });

  /// The (optionally parsed) data.
  final T data;

  /// Errors that accompanied partial data. Only non-empty with
  /// `ErrorPolicy.all`.
  final List<GraphQLError> errors;

  /// Where [data] came from.
  final ResultSource source;

  /// The response's `extensions` object, when it came from the network.
  final JsonMap? extensions;

  /// Whether [errors] is non-empty (partial data).
  bool get hasErrors => errors.isNotEmpty;

  @override
  String toString() => 'GraphQLSuccess(${source.name}: $data'
      '${hasErrors ? ', errors: $errors' : ''})';
}

/// A failed operation.
final class GraphQLFailure<T> extends GraphQLResult<T> {
  /// Creates a failure.
  const GraphQLFailure(this.exception);

  /// What went wrong.
  final GraphQLException exception;

  @override
  String toString() => 'GraphQLFailure($exception)';
}
