library;

/// Core functionality exports
export 'src/core/config/graphql_config.dart';
export 'src/core/caching/cache_policy.dart';
export 'src/core/caching/cache_manager.dart';
export 'src/core/errors/graphql_exception.dart';

/// Interceptors exports
export 'src/core/interceptors/auth_interceptor.dart';
export 'src/core/interceptors/logging_interceptor.dart';
export 'src/core/interceptors/retry_interceptor.dart';

/// Entity exports
export 'src/domain/entities/graphql_response.dart';
export 'src/domain/entities/graphql_error.dart';
export 'src/domain/entities/batch_response.dart';
export 'src/domain/entities/location.dart';

/// Repository exports
export 'src/domain/repositories/graphql_repository.dart';
export 'src/data/repositories/graphql_repository_impl.dart';
export 'src/data/repositories/graphql_subscription_repository.dart';

/// Client exports
export 'src/graphql_client_base.dart';

/// Type definitions and utilities
export 'src/core/typedefs/graphql_types.dart';
export 'src/core/utils/query_transformer.dart';
export 'src/core/utils/response_parser.dart';

/// Error handling
export 'src/core/errors/graphql_error_handler.dart';