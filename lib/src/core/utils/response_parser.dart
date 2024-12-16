import '../../../graphql_client_flutter.dart';

/// Utility class for parsing GraphQL responses
class ResponseParser {
  /// Parses a raw GraphQL response into a typed response
  static GraphQLResponse<T> parse<T>(Map<String, dynamic> json) {
    try {
      return GraphQLResponse<T>(
        data: _parseData<T>(json['data']),
        errors: _parseErrors(json['errors']),
        extensions: json['extensions'] as Map<String, dynamic>?,
      );
    } catch (e) {
      throw GraphQLException(
        message: 'Failed to parse GraphQL response: ${e.toString()}',
        extensions: {'type': 'parse_error'},
      );
    }
  }

    /// Validates response structure and throws if invalid
  static void validate(Map<String, dynamic> json) {
    if (!isValidResponse(json)) {
      throw GraphQLException(
        message: 'Invalid GraphQL response structure',
        extensions: {
          'type': 'validation_error',
          'missing_fields': [
            if (!json.containsKey('data')) 'data',
            if (!json.containsKey('errors')) 'errors',
          ],
        },
      );
    }

    // Validate errors structure if present
    if (json.containsKey('errors')) {
      try {
        _parseErrors(json['errors']);
      } catch (e) {
        throw GraphQLException(
          message: 'Invalid errors format in response',
          extensions: {'type': 'validation_error'},
        );
      }
    }

    // Validate extensions if present
    if (json.containsKey('extensions') &&
        json['extensions'] is! Map<String, dynamic>) {
      throw GraphQLException(
        message: 'Invalid extensions format in response',
        extensions: {'type': 'validation_error'},
      );
    }
  }

  /// Parses data with optional type conversion
  static T? _parseData<T>(dynamic data) {
    if (data == null) return null;
    
    if (data is T) return data;
    
    if (data is Map<String, dynamic>) {
      return data as T;
    }
    
    throw GraphQLException(
      message: 'Invalid data type',
      extensions: {
        'type': 'parse_error',
        'expected': T.toString(),
        'received': data.runtimeType.toString(),
      },
    );
  }

  /// Parses GraphQL errors from response
  static List<GraphQLError>? _parseErrors(dynamic errors) {
    if (errors == null) return null;
    
    if (errors is! List) {
      throw GraphQLException(
        message: 'Invalid errors format',
        extensions: {'type': 'parse_error'},
      );
    }

    return errors
        .map((e) => GraphQLError.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Parses a batch response
  static List<GraphQLResponse<T>> parseBatch<T>(List<dynamic> responses) {
    return responses
        .map((response) => parse<T>(response as Map<String, dynamic>))
        .toList();
  }

  /// Validates response structure
  static bool isValidResponse(Map<String, dynamic> json) {
    return json.containsKey('data') || json.containsKey('errors');
  }

  /// Extracts error messages from response
  static List<String> getErrorMessages(Map<String, dynamic> json) {
    final errors = _parseErrors(json['errors']);
    return errors?.map((e) => e.message).toList() ?? [];
  }

  /// Parses subscription data
  static GraphQLResponse<T> parseSubscriptionMessage<T>(
    Map<String, dynamic> message,
  ) {
    switch (message['type']) {
      case 'data':
        return parse<T>(message['payload'] as Map<String, dynamic>);
        
      case 'error':
        throw GraphQLException(
          message: 'Subscription error',
          errors: [
            GraphQLError(
              message: message['payload']['message'] as String,
              extensions: message['payload']['extensions'] as Map<String, dynamic>?,
            ),
          ],
        );
        
      case 'complete':
        throw GraphQLException(
          message: 'Subscription completed',
          extensions: {'type': 'subscription_complete'},
        );
        
      default:
        throw GraphQLException(
          message: 'Unknown subscription message type',
          extensions: {'type': 'unknown_message_type'},
        );
    }
  }
}