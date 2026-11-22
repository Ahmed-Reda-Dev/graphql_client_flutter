import 'package:source_span/source_span.dart';

/// A problem in the schema or a document, reported with its location.
final class CodegenException implements Exception {
  /// Creates an exception for [message] at [span] (if known).
  const CodegenException(this.message, [this.span]);

  /// What is wrong.
  final String message;

  /// Where, in the schema or a `.graphql` file.
  final SourceSpan? span;

  @override
  String toString() {
    final span = this.span;
    if (span == null) return message;
    final file = span.sourceUrl?.toString() ?? 'document';
    return '$file:${span.start.line + 1}:${span.start.column + 1}: $message';
  }
}
