import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../json.dart';

/// A position in the GraphQL document an error refers to.
@immutable
final class ErrorLocation {
  /// Creates a location.
  const ErrorLocation({required this.line, required this.column});

  /// Parses a location from its JSON representation.
  factory ErrorLocation.fromJson(JsonMap json) => ErrorLocation(
        line: (json['line'] as num).toInt(),
        column: (json['column'] as num).toInt(),
      );

  /// 1-based line number.
  final int line;

  /// 1-based column number.
  final int column;

  /// The JSON representation of this location.
  JsonMap toJson() => {'line': line, 'column': column};

  @override
  bool operator ==(Object other) =>
      other is ErrorLocation && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(line, column);

  @override
  String toString() => '$line:$column';
}

/// An error returned by a GraphQL server in the `errors` array.
///
/// See the [GraphQL spec](https://spec.graphql.org/October2021/#sec-Errors).
@immutable
final class GraphQLError {
  /// Creates an error.
  const GraphQLError({
    required this.message,
    this.locations = const [],
    this.path = const [],
    this.extensions = const {},
  });

  /// Parses an error from its JSON representation.
  ///
  /// Missing or malformed optional fields are ignored rather than throwing,
  /// because servers differ in what they include.
  factory GraphQLError.fromJson(JsonMap json) {
    final locations = json['locations'];
    final path = json['path'];
    final extensions = json['extensions'];
    return GraphQLError(
      message: json['message'] as String? ?? 'Unknown GraphQL error',
      locations: locations is List
          ? locations.whereType<JsonMap>().map(ErrorLocation.fromJson).toList()
          : const [],
      path: path is List ? List<Object>.unmodifiable(path.nonNulls) : const [],
      extensions: extensions is JsonMap ? extensions : const {},
    );
  }

  /// Human-readable description of the error.
  final String message;

  /// Where in the document the error occurred.
  final List<ErrorLocation> locations;

  /// Path to the response field that failed (field names and list indexes).
  final List<Object> path;

  /// Server-specific details, such as `code`.
  final JsonMap extensions;

  /// The conventional `extensions.code` value, e.g. `UNAUTHENTICATED`.
  String? get code => extensions['code'] as String?;

  /// The JSON representation of this error.
  JsonMap toJson() => {
        'message': message,
        if (locations.isNotEmpty)
          'locations': locations.map((l) => l.toJson()).toList(),
        if (path.isNotEmpty) 'path': path,
        if (extensions.isNotEmpty) 'extensions': extensions,
      };

  static const _equality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is GraphQLError &&
      other.message == message &&
      _equality.equals(other.locations, locations) &&
      _equality.equals(other.path, path) &&
      _equality.equals(other.extensions, extensions);

  @override
  int get hashCode => Object.hash(
        message,
        _equality.hash(locations),
        _equality.hash(path),
        _equality.hash(extensions),
      );

  @override
  String toString() {
    final where = path.isEmpty ? '' : ' at ${path.join('.')}';
    return 'GraphQLError($message$where)';
  }
}
