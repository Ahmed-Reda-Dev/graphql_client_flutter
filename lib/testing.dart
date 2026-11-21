/// Test utilities for apps built with graphql_client_flutter.
///
/// ```dart
/// import 'package:graphql_client_flutter/testing.dart';
///
/// final mock = MockTransport()..on('GetUser').reply({'user': {...}});
/// final client = GraphQLClient.custom(transport: mock);
/// ```
library;

export 'src/testing/mock_transport.dart';
