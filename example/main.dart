import 'package:graphql_client_flutter/graphql_client_flutter.dart';

void main() async {
  // Initialize client configuration
  final config = GraphQLConfig(
    endpoint: 'https://api.example.com/graphql',
    subscriptionEndpoint: 'wss://api.example.com/graphql',
    defaultCachePolicy: CachePolicy.cacheFirst,
    defaultTimeout: Duration(seconds: 30),
    enableLogging: true,
    maxRetries: 3,
    retryDelay: Duration(seconds: 1),
    defaultHeaders: {
      'Authorization': 'Bearer YOUR_TOKEN',
    },
  );

  // Create GraphQL client instance
  final client = GraphQLClientBase(config: config);

  try {
    // Execute a query with caching
    final usersResponse = await client.query<Map<String, dynamic>>(
      '''
      query GetUsers(\$limit: Int, \$offset: Int) {
        users(limit: \$limit, offset: \$offset) {
          id
          name
          email
          posts {
            id
            title
          }
        }
      }
      ''',
      variables: {
        'limit': 10,
        'offset': 0,
      },
      cachePolicy: CachePolicy.cacheFirst,
      ttl: Duration(minutes: 5),
    );

    print('Users: ${usersResponse.data?['users']}');

    // Execute a mutation
    final createUserResponse = await client.mutate<Map<String, dynamic>>(
      '''
      mutation CreateUser(\$input: CreateUserInput!) {
        createUser(input: \$input) {
          id
          name
          email
        }
      }
      ''',
      variables: {
        'input': {
          'name': 'John Doe',
          'email': 'john@example.com',
        }
      },
      // Invalidate cached queries after mutation
      invalidateCache: ['GetUsers'],
    );

    print('Created user: ${createUserResponse.data?['createUser']}');

    // Execute batch operations
    final batchResponse = await client.batch([
      BatchOperation(
        query: 'query GetUser(\$id: ID!) { user(id: \$id) { id name } }',
        variables: {'id': '1'},
      ),
      BatchOperation(
        query: 'query GetPosts { posts { id title } }',
      ),
    ]);

    print('Batch responses: ${batchResponse.responses}');

    // Set up subscription if supported
    if (client.hasSubscriptionSupport) {
      final subscription = client.subscribe<Map<String, dynamic>>(
        '''
        subscription OnUserUpdated {
          userUpdated {
            id
            name
            email
          }
        }
        ''',
      ).listen(
        (response) {
          print('User updated: ${response.data?['userUpdated']}');
        },
        onError: (error) {
          print('Subscription error: $error');
        },
      );

      // Handle cache operations
      await client.clearCache();

      final cacheStats = await client.getCacheStats();
      print('Cache stats: $cacheStats');

      // Validate a query
      final isValid = await client.validateQuery(
        '''
        query ValidateMe {
          users { invalidField }
        }
        ''',
      );
      print('Query is valid: $isValid');

      // Get schema information
      final schema = await client.getSchema();
      print('Schema types: ${schema.data?['__schema']['types']}');

      // Use convenience methods
      final cachedResponse = await client.queryCacheFirst(
        'query GetCachedUsers { users { id name } }',
      );
      print('Cached users: ${cachedResponse.data}');

      final networkResponse = await client.queryNetworkOnly(
        'query GetFreshUsers { users { id name } }',
      );
      print('Fresh users: ${networkResponse.data}');

      // Cleanup resources
      await subscription.cancel();
      await client.dispose();
    }
  } on GraphQLException catch (e) {
    // Handle GraphQL-specific errors
    print('GraphQL Error: ${e.message}');
    if (e.errors != null) {
      for (final error in e.errors!) {
        print(' - ${error.message}');
        print('   Location: ${error.locations}');
        print('   Path: ${error.path}');
        print('   Extensions: ${error.extensions}');
      }
    }
  } catch (e) {
    print('Error: $e');
  }
}
