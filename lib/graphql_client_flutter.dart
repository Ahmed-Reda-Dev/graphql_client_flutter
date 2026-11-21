/// The simple, typed GraphQL client for Flutter.
///
/// Start with [GraphQLClient], wrap your app in [GraphQLProvider], and use
/// [GraphQLQuery], [GraphQLMutation] and [GraphQLSubscription] widgets.
library;

export 'package:dio/dio.dart'
    show HttpClientAdapter, Interceptor, MultipartFile;
export 'package:normalize/normalize.dart' show FieldPolicy, TypePolicy;
export 'package:normalize/utils.dart' show DataIdResolver;

export 'src/core/cache/graphql_cache.dart';
export 'src/core/cache/store/store.dart';
export 'src/core/client/graphql_observer.dart' show GraphQLObserver;
export 'src/core/client/observable_query.dart';
export 'src/core/client/query_manager.dart' show CacheUpdater;
export 'src/core/client/result_mapper.dart' show DataParser;
export 'src/core/json.dart';
export 'src/core/request/cancellation_token.dart';
export 'src/core/request/graphql_document.dart';
export 'src/core/request/graphql_request.dart';
export 'src/core/request/policies.dart';
export 'src/core/response/graphql_error.dart';
export 'src/core/response/graphql_exception.dart';
export 'src/core/response/graphql_response.dart';
export 'src/core/response/graphql_result.dart';
export 'src/core/transport/graphql_transport.dart';
export 'src/core/transport/http/http_transport.dart';
export 'src/core/transport/http/interceptors/auth_interceptor.dart';
export 'src/core/transport/http/interceptors/dio_aware_interceptor.dart'
    show DioAwareInterceptor;
export 'src/core/transport/http/interceptors/logging_interceptor.dart';
export 'src/core/transport/http/interceptors/retry_interceptor.dart';
export 'src/core/transport/websocket/subscription_protocol.dart';
export 'src/core/transport/websocket/websocket_transport.dart';
