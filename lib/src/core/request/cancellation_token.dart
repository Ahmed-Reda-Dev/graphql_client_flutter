import 'dart:async';

/// Cancels an in-flight operation.
///
/// ```dart
/// final token = CancellationToken();
/// final future = client.query(search, cancelToken: token);
/// token.cancel(); // future completes with GraphQLErrorKind.cancelled
/// ```
final class CancellationToken {
  /// Creates a token that has not been cancelled.
  CancellationToken();

  final Completer<void> _completer = Completer<void>();
  Object? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// The value passed to [cancel], if any.
  Object? get reason => _reason;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  /// Cancels the operation. Calling it again has no effect.
  void cancel([Object? reason]) {
    if (isCancelled) return;
    _reason = reason;
    _completer.complete();
  }
}
