import 'package:dio/dio.dart';
import 'graphql_exception.dart';
import '../../domain/entities/graphql_error.dart';
import '../config/graphql_config.dart';

/// Handles error cases in GraphQL operations uniformly
class GraphQLErrorHandler {
  final ErrorHandlingStrategy strategy;
  final void Function(GraphQLException)? onError;

  const GraphQLErrorHandler({
    this.strategy = ErrorHandlingStrategy.throwError,
    this.onError,
  });

  /// Handles various types of errors that can occur during GraphQL operations
  T handleError<T>(dynamic error, {
    String? operationType,
    String? operationName,
  }) {
    final exception = _createException(error, operationType, operationName);
    
    switch (strategy) {
      case ErrorHandlingStrategy.throwError:
        throw exception;
        
      case ErrorHandlingStrategy.showDialog:
        onError?.call(exception);
        throw exception;
        
      case ErrorHandlingStrategy.silent:
        onError?.call(exception);
        return null as T;
        
      case ErrorHandlingStrategy.custom:
        onError?.call(exception);
        throw exception;
    }
  }

  /// Creates a standardized GraphQLException from various error types
  GraphQLException _createException(
    dynamic error,
    String? operationType,
    String? operationName,
  ) {
    if (error is GraphQLException) {
      return error;
    }

    if (error is DioException) {
      return GraphQLException(
        message: 'Network error occurred: ${error.message}',
        originalException: error,
        statusCode: error.response?.statusCode,
        extensions: {
          'type': 'network_error',
          'url': error.requestOptions.uri.toString(),
          'method': error.requestOptions.method,
        },
        operationType: operationType,
        operationName: operationName,
      );
    }

    if (error is Map<String, dynamic> && error.containsKey('errors')) {
      final errors = (error['errors'] as List)
          .map((e) => GraphQLError.fromJson(e as Map<String, dynamic>))
          .toList();
          
      return GraphQLException(
        message: 'GraphQL errors occurred',
        errors: errors,
        extensions: error['extensions'] as Map<String, dynamic>?,
        operationType: operationType,
        operationName: operationName,
      );
    }

    return GraphQLException(
      message: 'An unexpected error occurred: ${error.toString()}',
      originalException: error is Exception ? error : null,
      operationType: operationType,
      operationName: operationName,
    );
  }

  /// Creates a formatted error message for logging
  String formatErrorMessage(GraphQLException exception) {
    return exception.getFormattedMessage(includeStackTrace: true);
  }

  /// Determines if an error should trigger a retry
  bool shouldRetry(GraphQLException exception) {
    return exception.isNetworkError && 
           !exception.isCacheError &&
           exception.statusCode != 400 && // Bad Request
           exception.statusCode != 401 && // Unauthorized
           exception.statusCode != 403;   // Forbidden
  }

  /// Gets appropriate error message for user display
  String getUserFriendlyMessage(GraphQLException exception) {
    if (exception.isNetworkError) {
      return 'Network connection error. Please check your internet connection.';
    }
    
    if (exception.isValidationError) {
      return 'Invalid request. Please check your input.';
    }
    
    if (exception.isCacheError) {
      return 'Data not available offline.';
    }
    
    return exception.message;
  }
}