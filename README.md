# GraphQL Client Flutter

A powerful, flexible, and feature-rich GraphQL client for Flutter applications. Simplify interactions with GraphQL APIs with built-in caching, error handling, real-time subscriptions, batch operations, and more.

![Flutter](https://img.shields.io/badge/flutter-%233952F5.svg?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/dart-%230175C2.svg?logo=dart&logoColor=white)
[![Pub Version](https://img.shields.io/pub/v/graphql_client_flutter.svg)](https://pub.dev/packages/graphql_client_flutter)
[![LICENSE](https://img.shields.io/github/license/Ahmed-Reda-Dev/graphql_client_flutter/graphql_client_flutter.svg)](LICENSE)
[![CI](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/workflows/CI/badge.svg)](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/actions)

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Usage](#usage)
  - [Configuring the Client](#configuring-the-client)
  - [Executing Queries](#executing-queries)
  - [Performing Mutations](#performing-mutations)
  - [Subscriptions](#subscriptions)
  - [Batch Operations](#batch-operations)
  - [Cache Management](#cache-management)
  - [Error Handling](#error-handling)
- [Advanced Configuration](#advanced-configuration)
  - [Custom Interceptors](#custom-interceptors)
  - [Retry Logic](#retry-logic)
  - [Logging Options](#logging-options)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)
- [Additional Information](#additional-information)

## Features

- **Full GraphQL Support**
  - Seamlessly handle queries, mutations, and subscriptions.
- **Advanced Caching**
  - Multiple cache policies (e.g., network-only, cache-first).
  - In-memory and persistent storage options.
  - Time-To-Live (TTL) support for cache entries.
- **Built-in Retry Mechanism**
  - Configurable retry attempts and delays.
  - Exponential backoff strategy.
- **Robust Error Handling**
  - Detailed error information with stack traces.
  - Customizable error handling strategies.
- **Comprehensive Logging**
  - Request and response logging.
  - Pretty-printing of GraphQL queries and JSON data.
- **Batch Operations**
  - Execute multiple operations in a single network request.
- **Subscriptions Support**
  - Real-time data updates with WebSocket subscriptions.
- **Clean Architecture**
  - Designed for maintainability and testability.

## Installation

Add the package to your project's `pubspec.yaml` file:

```yaml
dependencies:
  graphql_client_flutter: ^1.0.0
```

Then run:

```bash
dart pub get
```

## Getting Started

To start using `graphql_client_flutter`, you need to configure the client with your GraphQL API endpoint.

### Example

```dart
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

void main() async {
  // Create client configuration
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

  // Initialize the client
  final client = GraphQLClientBase(config: config);

  // Use the client to perform operations
}
```

## Usage

### Configuring the Client

First, import the package and create a configuration:

```dart
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

void main() async {
  // Create client configuration
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

  // Initialize the client
  final client = GraphQLClientBase(config: config);

  // ... Use the client
}
```

### Executing Queries

Perform a GraphQL query using the `query` method:

```dart
final response = await client.query<Map<String, dynamic>>(
  '''
  query GetUsers(\$limit: Int) {
    users(limit: \$limit) {
      id
      name
      email
    }
  }
  ''',
  variables: {'limit': 10},
  cachePolicy: CachePolicy.cacheAndNetwork,
  ttl: Duration(minutes: 10),
);

if (response.hasErrors) {
  print('Errors: ${response.errors}');
} else {
  print('Users: ${response.data?['users']}');
}
```

### Performing Mutations

Execute a GraphQL mutation using the `mutate` method:

```dart
final response = await client.mutate<Map<String, dynamic>>(
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
      'name': 'Jane Doe',
      'email': 'jane@example.com',
    },
  },
  invalidateCache: ['GetUsers'], // Specify queries to invalidate
);

if (response.hasErrors) {
  print('Errors: ${response.errors}');
} else {
  print('Created User: ${response.data?['createUser']}');
}
```

### Subscriptions

Subscribe to real-time data using the `subscribe` method:

```dart
final subscription = client.subscribe<Map<String, dynamic>>(
  '''
  subscription OnNewUser {
    userCreated {
      id
      name
      email
    }
  }
  ''',
).listen(
  (response) {
    print('New User: ${response.data?['userCreated']}');
  },
  onError: (error) {
    print('Subscription error: $error');
  },
);

// Remember to cancel the subscription when done
await subscription.cancel();
```

### Batch Operations

Perform multiple operations in a single network request using the `batch` method:

```dart
final batchResponse = await client.batch([
  BatchOperation(
    query: '''
      query GetUser(\$id: ID!) {
        user(id: \$id) {
          id
          name
        }
      }
    ''',
    variables: {'id': '1'},
  ),
  BatchOperation(
    query: '''
      mutation UpdateUser(\$id: ID!, \$input: UpdateUserInput!) {
        updateUser(id: \$id, input: \$input) {
          id
          name
          email
        }
      }
    ''',
    variables: {
      'id': '1',
      'input': {'name': 'Updated Name'},
    },
  ),
]);

// Access individual responses
final getUserResponse = batchResponse.responses[0];
final updateUserResponse = batchResponse.responses[1];
```

### Cache Management

Manage the cache using provided methods:

```dart
// Clear the entire cache
await client.clearCache();

// Invalidate specific queries
await client.invalidateQueries(['GetUsers', 'GetUser']);

// Get cache statistics
final stats = await client.getCacheStats();
print('Cache Stats: $stats');
```

### Error Handling

Handle errors gracefully:

```dart
try {
  final response = await client.query('your query');
  if (response.hasErrors) {
    // Handle GraphQL errors
    for (final error in response.errors!) {
      print('Error: ${error.message}');
    }
  } else {
    // Use response data
  }
} on GraphQLException catch (e) {
  // Handle exceptions thrown by the client
  print('GraphQL Exception: ${e.message}');
} catch (e) {
  // Handle any other exceptions
  print('General Exception: $e');
}
```

## Advanced Configuration

### Custom Interceptors

You can provide custom interceptors to extend the client's functionality:

```dart
final client = GraphQLClientBase(
  config: config,
  interceptors: [
    MyCustomInterceptor(),
    // Add other interceptors
  ],
);
```

### Retry Logic

Configure retry behavior for failed requests:

```dart
final config = GraphQLConfig(
  endpoint: 'https://api.example.com/graphql',
  maxRetries: 5,
  retryDelay: Duration(seconds: 2),
  // Optionally provide a custom shouldRetry function
);
```

### Logging Options

Fine-tune logging settings using the `LoggingInterceptor`:

```dart
final client = GraphQLClientBase(
  config: config,
  interceptors: [
    LoggingInterceptor(
      options: LoggingOptions(
        logRequests: true,
        logResponses: true,
        logErrors: true,
      ),
      prettyPrintJson: true,
    ),
  ],
);
```

## Testing

This package includes comprehensive tests to ensure reliability and correctness. To run the tests, use the following command:

```bash
dart test test/graphql_client_test.dart
```

Ensure you have the necessary dev dependencies installed as specified in the `pubspec.yaml`:

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  lints: ^5.0.0
  mockito: ^5.4.4
  test: ^1.24.0
```

## Contributing

Contributions are welcome! Please follow these steps:

1. **Fork the repository.**
2. **Create a new branch** for your feature or bug fix.
3. **Write tests** for your changes.
4. **Ensure all tests pass**.
5. **Submit a pull request** with a detailed description of your changes.

For more details on how to contribute, refer to the [CONTRIBUTING.md](CONTRIBUTING.md) file.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Additional Information

- **GitHub Repository**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter)
- **Issue Tracker**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues)
- **API Documentation**: [https://pub.dev/documentation/graphql_client_flutter/latest/graphql_client_flutter/graphql_client_flutter-library.html](https://pub.dev/documentation/graphql_client_flutter/latest/graphql_client_flutter/graphql_client_flutter-library.html)
- **Examples**: Check out the [example](example/) directory for comprehensive usage examples.

---

*Maintained by Ahmed Reda. For support or questions, please open an issue on [GitHub](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues).*