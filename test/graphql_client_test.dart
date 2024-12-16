import 'package:dio/dio.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

@GenerateMocks([Dio, CacheManager, Response])
class MockDio extends Mock implements Dio {}
class MockCacheManager extends Mock implements CacheManager {}
class MockResponse extends Mock implements Response {}

void main() {
  late GraphQLClientBase client;
  late MockDio mockDio;
  late MockCacheManager mockCache;
  late GraphQLConfig config;
  
  setUp(() {
    mockDio = MockDio();
    mockCache = MockCacheManager();
    
    // Setup default mock behavior
    when(mockDio.options).thenReturn(BaseOptions());
    when(mockCache.clear()).thenAnswer((_) => Future.value());
    
    config = GraphQLConfig(
      endpoint: 'https://api.example.com/graphql',
      defaultCachePolicy: CachePolicy.networkOnly,
      enableLogging: true,
      maxRetries: 2,
      retryDelay: Duration(milliseconds: 100),
    );
    
    // Pass mockDio to the client through interceptors
    client = GraphQLClientBase(
      config: config,
      cacheManager: mockCache,
      interceptors: [
        // Inject mockDio for testing
        InterceptorsWrapper(
          onRequest: (options, handler) {
            mockDio.fetch(options).then(
              (response) => handler.resolve(response),
              onError: (error) => handler.reject(error),
            );
          },
        ),
      ],
    );
  });

  tearDown(() async {
    // Reset mocks and clear cache between tests
    reset(mockDio);
    reset(mockCache);
    await client.dispose();
  });

  // ... rest of test groups remain the same ...

  group('Retry Behavior', () {
    test('retries failed requests according to config', () async {
      int attempts = 0;
      when(mockDio.post(
        '',
        data: any,
        options: any,
      )).thenAnswer((_) async {
        attempts++;
        if (attempts < config.maxRetries) {
          throw DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionTimeout,
          );
        }
        return MockResponse()..data = {'data': {'test': 'success'}};
      });

      final result = await client.query('query { test }');
      expect(attempts, equals(config.maxRetries));
      expect(result.data?['test'], equals('success'));
    });
  });

  group('Subscription Tests', () {
    test('throws error when subscription endpoint not configured', () {
      expect(
        () => client.subscribe('subscription { test }'),
        throwsA(isA<GraphQLException>()),
      );
    });
  });

  group('Error Handler Tests', () {
    test('handles custom error strategy', () async {
      List<GraphQLException> caughtErrors = [];
      
      client = GraphQLClientBase(
        config: config.copyWith(
          errorHandling: ErrorHandlingStrategy.custom,
          onError: (error) => caughtErrors.add(error),
        ),
        cacheManager: mockCache,
      );

      when(mockDio.post('', data: any, options: any))
          .thenThrow(DioException(
        requestOptions: RequestOptions(),
        error: 'Test Error',
      ));

      await client.query('query { test }');
      expect(caughtErrors.length, equals(1));
      expect(caughtErrors.first.message, contains('Test Error'));
    });
  });
}