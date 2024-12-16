import 'location.dart';

/// Represents a GraphQL error returned from the server
class GraphQLError {
  /// The error message
  final String message;

  /// The locations where the error occurred in the GraphQL document
  final List<Location>? locations;

  /// The path to the response field that encountered the error
  final List<dynamic>? path;

  /// Additional error metadata provided by the server
  final Map<String, dynamic>? extensions;

  /// The error code if available
  String? get errorCode => extensions?['code'] as String?;

  /// Whether this is a network error
  bool get isNetworkError =>
      errorCode == 'NETWORK_ERROR' || extensions?['type'] == 'network_error';

  /// Whether this is a validation error
  bool get isValidationError =>
      errorCode == 'GRAPHQL_VALIDATION_FAILED' ||
      extensions?['type'] == 'validation_error';

  GraphQLError({
    required this.message,
    this.locations,
    this.path,
    this.extensions,
  });

  /// Creates a GraphQLError from a JSON map
  factory GraphQLError.fromJson(Map<String, dynamic> json) {
    return GraphQLError(
      message: json['message'] as String,
      locations: (json['locations'] as List?)
          ?.map((e) => Location.fromJson(e as Map<String, dynamic>))
          .toList(),
      path: json['path'] as List<dynamic>?,
      extensions: json['extensions'] as Map<String, dynamic>?,
    );
  }

  /// Creates a network error
  factory GraphQLError.network(String message) {
    return GraphQLError(
      message: message,
      extensions: {
        'code': 'NETWORK_ERROR',
        'type': 'network_error',
      },
    );
  }

  /// Creates a validation error
  factory GraphQLError.validation(String message) {
    return GraphQLError(
      message: message,
      extensions: {
        'code': 'GRAPHQL_VALIDATION_FAILED',
        'type': 'validation_error',
      },
    );
  }

  /// Creates a parsing error
  factory GraphQLError.parsing(String message) {
    return GraphQLError(
      message: message,
      extensions: {
        'code': 'GRAPHQL_PARSE_FAILED',
        'type': 'parse_error',
      },
    );
  }

  /// Converts the error to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'message': message,
      if (locations != null)
        'locations': locations!
            .map((l) => {
                  'line': l.line,
                  'column': l.column,
                })
            .toList(),
      if (path != null) 'path': path,
      if (extensions != null) 'extensions': extensions,
    };
  }

  /// Gets a formatted error message including location and path information
  String getFormattedMessage() {
    final buffer = StringBuffer(message);

    if (path != null) {
      buffer.write('\nPath: ${path!.join('.')}');
    }

    if (locations != null) {
      for (final location in locations!) {
        buffer.write(
            '\nLocation: line ${location.line}, column ${location.column}');
      }
    }

    if (extensions != null) {
      buffer.write('\nExtensions: $extensions');
    }

    return buffer.toString();
  }

  /// Gets the deepest path segment where the error occurred
  String? get fieldName => path?.lastOrNull?.toString();

  /// Whether this error has a specific location
  bool get hasLocation => locations != null && locations!.isNotEmpty;

  /// Whether this error has extension data
  bool get hasExtensions => extensions != null && extensions!.isNotEmpty;

  @override
  String toString() => getFormattedMessage();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphQLError &&
          message == other.message &&
          _listEquals(locations, other.locations) &&
          _listEquals(path, other.path) &&
          _mapEquals(extensions, other.extensions);

  @override
  int get hashCode =>
      message.hashCode ^
      locations.hashCode ^
      path.hashCode ^
      extensions.hashCode;
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}
