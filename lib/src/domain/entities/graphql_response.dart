import 'graphql_error.dart';

/// Represents a response from a GraphQL operation
class GraphQLResponse<T> {
  /// The data returned from the operation
  final T? data;

  /// Any errors that occurred during the operation
  final List<GraphQLError>? errors;

  /// Additional metadata returned by the server
  final Map<String, dynamic>? extensions;

  /// Creates a new GraphQLResponse instance
  GraphQLResponse({
    this.data,
    this.errors,
    this.extensions,
  });

  /// Whether this response contains any errors
  bool get hasErrors => errors != null && errors!.isNotEmpty;

  /// Whether this response contains data
  bool get hasData => data != null;

  /// Whether this response is successful (has data and no errors)
  bool get isSuccessful => hasData && !hasErrors;

  /// Creates a GraphQLResponse from a JSON map
  factory GraphQLResponse.fromJson(Map<String, dynamic> json) {
    return GraphQLResponse(
      data: json['data'] as T?,
      errors: json['errors'] != null
          ? (json['errors'] as List)
              .map((e) => GraphQLError.fromJson(e as Map<String, dynamic>))
              .toList()
          : null,
      extensions: json['extensions'] as Map<String, dynamic>?,
    );
  }

  /// Creates a successful response with just data
  factory GraphQLResponse.success(T data) {
    return GraphQLResponse(data: data);
  }

  /// Creates an error response
  factory GraphQLResponse.error(List<GraphQLError> errors) {
    return GraphQLResponse(errors: errors);
  }

  /// Converts the response to a JSON map
  Map<String, dynamic> toJson() {
    return {
      if (data != null) 'data': data,
      if (errors != null) 'errors': errors!.map((e) => e.toJson()).toList(),
      if (extensions != null) 'extensions': extensions,
    };
  }

  /// Gets all error messages if any exist
  List<String> get errorMessages =>
      errors?.map((e) => e.message).toList() ?? [];

  /// Gets the first error message if any exists
  String? get firstErrorMessage => errors?.firstOrNull?.message;

  /// Gets a value from the extensions map
  // ignore: avoid_shadowing_type_parameters
  T? getExtension<T>(String key) => extensions?[key] as T?;

  /// Transforms the response data using the given mapper function
  GraphQLResponse<R> map<R>(R Function(T? data) mapper) {
    return GraphQLResponse(
      data: mapper(data),
      errors: errors,
      extensions: extensions,
    );
  }

  /// Returns the data or throws an exception if there are errors
  T? getDataOrThrow() {
    if (hasErrors) {
      throw errors!.first;
    }
    return data;
  }

  @override
  String toString() {
    final buffer = StringBuffer('GraphQLResponse(');
    if (hasData) {
      buffer.write('data: $data');
    }
    if (hasErrors) {
      if (hasData) buffer.write(', ');
      buffer.write('errors: $errors');
    }
    if (extensions != null) {
      if (hasData || hasErrors) buffer.write(', ');
      buffer.write('extensions: $extensions');
    }
    buffer.write(')');
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphQLResponse &&
          data == other.data &&
          _listEquals(errors, other.errors) &&
          _mapEquals(extensions, other.extensions);

  @override
  int get hashCode => data.hashCode ^ errors.hashCode ^ extensions.hashCode;
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
