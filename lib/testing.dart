/// Test utilities for apps built with graphql_client_flutter.
///
/// ```dart
/// import 'package:graphql_client_flutter/testing.dart';
///
/// // Canned replies:
/// final mock = MockTransport()..on('GetUser').reply({'user': {...}});
/// final client = GraphQLClient.custom(transport: mock);
///
/// // Or replay real server answers recorded with RecordingTransport:
/// final replay = ReplayTransport(await Cassette.load('test/fixtures/home.json'));
/// ```
library;

export 'src/testing/cassette.dart';
export 'src/testing/mock_transport.dart';
export 'src/testing/recording_transport.dart';
export 'src/testing/replay_transport.dart';
