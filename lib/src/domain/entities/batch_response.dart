import 'graphql_response.dart';

/// Represents a response from a batched GraphQL operation
class BatchResponse {
  /// List of individual responses for each operation in the batch
  final List<GraphQLResponse> responses;

  BatchResponse({required this.responses});

  /// Whether any of the operations in the batch resulted in errors
  bool get hasErrors => responses.any((response) => response.hasErrors);

  /// Gets all error messages from all operations that had errors
  List<String> get allErrorMessages => responses
      .where((response) => response.hasErrors)
      .expand((response) => response.errors?.map((e) => e.message) ?? [])
      .cast<String>()
      .toList();

  /// Gets all successful responses (those without errors)
  List<GraphQLResponse> get successfulResponses =>
      responses.where((response) => !response.hasErrors).toList();

  /// Gets all failed responses (those with errors)
  List<GraphQLResponse> get failedResponses =>
      responses.where((response) => response.hasErrors).toList();

  /// Number of operations in the batch
  int get length => responses.length;

  /// Whether all operations in the batch were successful
  bool get isCompletelySuccessful => !hasErrors;

  /// Gets the response at the specified index with type safety
  GraphQLResponse<T> getResponse<T>(int index) {
    if (index < 0 || index >= responses.length) {
      throw RangeError('Index out of range');
    }
    return responses[index] as GraphQLResponse<T>;
  }
}

/// Extension methods for working with batch responses
extension BatchResponseExtension on BatchResponse {
  /// Maps responses to a specific type
  List<GraphQLResponse<T>> mapResponses<T>() {
    return responses.map((response) => response as GraphQLResponse<T>).toList();
  }

  /// Gets successful responses of a specific type
  List<T> getSuccessfulData<T>() {
    return successfulResponses
        .map((response) => response.data as T)
        .where((data) => data != null)
        .toList();
  }
}