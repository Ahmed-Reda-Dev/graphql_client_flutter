import '../core/response/graphql_error.dart';
import '../core/response/graphql_exception.dart';
import '../core/response/graphql_result.dart';

/// What a query or subscription widget should show.
///
/// ```dart
/// builder: (context, state, query) => switch (state) {
///   QueryLoading() => const CircularProgressIndicator(),
///   QueryData(:final data) => Text(data.name),
///   QueryError(:final exception) => Text(exception.userMessage),
/// },
/// ```
sealed class QueryState<T> {
  const QueryState();

  /// The data to show, if any: current data, or the last data before an
  /// error.
  T? get data => switch (this) {
        QueryLoading() => null,
        QueryData(:final data) => data,
        QueryError(:final previousData) => previousData,
      };
}

/// No data yet; the first result is loading.
final class QueryLoading<T> extends QueryState<T> {
  /// Creates the loading state.
  const QueryLoading();
}

/// Data is available.
final class QueryData<T> extends QueryState<T> {
  /// Creates the data state.
  const QueryData(
    this.data, {
    this.source = ResultSource.network,
    this.errors = const [],
    this.isRefreshing = false,
  });

  @override
  final T data;

  /// Where [data] came from.
  final ResultSource source;

  /// Errors returned alongside partial data (`ErrorPolicy.all`).
  final List<GraphQLError> errors;

  /// Whether a refetch is in progress.
  final bool isRefreshing;

  /// Returns a copy with [isRefreshing] changed.
  QueryData<T> copyWith({bool? isRefreshing}) => QueryData(
        data,
        source: source,
        errors: errors,
        isRefreshing: isRefreshing ?? this.isRefreshing,
      );
}

/// The operation failed.
final class QueryError<T> extends QueryState<T> {
  /// Creates the error state.
  const QueryError(this.exception, {this.previousData});

  /// What went wrong.
  final GraphQLException exception;

  /// Data shown before the failure, so the UI can keep it visible.
  final T? previousData;
}

/// Converts results into [QueryState]s.
extension QueryStateFromResult<T> on GraphQLResult<T> {
  /// This result as a state, keeping [previous] data on failure.
  QueryState<T> toQueryState({T? previous}) => switch (this) {
        GraphQLSuccess(:final data, :final source, :final errors) =>
          QueryData(data, source: source, errors: errors),
        GraphQLFailure(:final exception) =>
          QueryError(exception, previousData: previous),
      };
}

/// What a mutation widget should show.
sealed class MutationState<T> {
  const MutationState();
}

/// The mutation has not run yet.
final class MutationIdle<T> extends MutationState<T> {
  /// Creates the idle state.
  const MutationIdle();
}

/// The mutation is running.
final class MutationRunning<T> extends MutationState<T> {
  /// Creates the running state.
  const MutationRunning();
}

/// The mutation succeeded.
final class MutationSuccess<T> extends MutationState<T> {
  /// Creates the success state.
  const MutationSuccess(this.data);

  /// The mutation's result.
  final T data;
}

/// The mutation failed.
final class MutationFailure<T> extends MutationState<T> {
  /// Creates the failure state.
  const MutationFailure(this.exception);

  /// What went wrong.
  final GraphQLException exception;
}
