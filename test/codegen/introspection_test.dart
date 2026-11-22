import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/src/codegen/codegen_exception.dart';
import 'package:graphql_client_flutter/src/codegen/introspection.dart';
import 'package:graphql_client_flutter/src/codegen/schema_index.dart';

typedef _Json = Map<String, dynamic>;

_Json _named(String kind, String name) => {'kind': kind, 'name': name};
_Json _nonNull(_Json of) => {'kind': 'NON_NULL', 'name': null, 'ofType': of};
_Json _list(_Json of) => {'kind': 'LIST', 'name': null, 'ofType': of};

void main() {
  final countries = (jsonDecode(
    File('test/codegen/fixtures/countries_introspection.json')
        .readAsStringSync(),
  ) as _Json)['data'] as _Json;

  group('introspectionToSdl', () {
    test('rebuilds a real schema that parses and keeps its types', () {
      final sdl = introspectionToSdl(countries);
      final schema = SchemaIndex.parse(sdl);

      expect(schema.field('Query', 'countries'), isNotNull);
      expect(schema.field('Country', 'name'), isNotNull);
      expect(sdl, contains('input StringQueryOperatorInput {'));
      expect(sdl, contains('  in: [String!]'));
      expect(sdl, isNot(contains('__Type')));
      expect(sdl, isNot(contains('scalar String')));
    });

    test('sorts types by name so diffs stay readable', () {
      final names = RegExp(r'^(?:type|input|enum|scalar|union|interface) (\w+)',
              multiLine: true)
          .allMatches(introspectionToSdl(countries))
          .map((m) => m.group(1)!)
          .toList();
      expect(names, [...names]..sort());
    });

    test('keeps roots, descriptions, defaults and deprecations', () {
      final sdl = introspectionToSdl({
        '__schema': {
          'queryType': {'name': 'Root'},
          'mutationType': null,
          'subscriptionType': null,
          'types': [
            {
              'kind': 'OBJECT',
              'name': 'Root',
              'description': 'Say """hi"""',
              'interfaces': [_named('INTERFACE', 'Node')],
              'fields': [
                {
                  'name': 'items',
                  'description': null,
                  'isDeprecated': true,
                  'deprecationReason': 'Use list',
                  'args': [
                    {
                      'name': 'first',
                      'description': null,
                      'type': _named('SCALAR', 'Int'),
                      'defaultValue': '10',
                    },
                  ],
                  'type': _nonNull(_list(_nonNull(_named('SCALAR', 'ID')))),
                },
                {
                  'name': 'id',
                  'isDeprecated': false,
                  'args': <Object?>[],
                  'type': _nonNull(_named('SCALAR', 'ID')),
                },
              ],
            },
            {
              'kind': 'INTERFACE',
              'name': 'Node',
              'interfaces': [_named('INTERFACE', 'Entity')],
              'fields': [
                {
                  'name': 'id',
                  'args': <Object?>[],
                  'type': _nonNull(_named('SCALAR', 'ID')),
                },
              ],
            },
            {
              'kind': 'INTERFACE',
              'name': 'Entity',
              'fields': [
                {
                  'name': 'id',
                  'args': <Object?>[],
                  'type': _nonNull(_named('SCALAR', 'ID')),
                },
              ],
            },
            {
              'kind': 'UNION',
              'name': 'Any',
              'possibleTypes': [_named('OBJECT', 'Root')],
            },
            {
              'kind': 'ENUM',
              'name': 'Color',
              'enumValues': [
                {'name': 'RED', 'isDeprecated': false},
                {'name': 'BLUE', 'isDeprecated': true},
              ],
            },
            {'kind': 'SCALAR', 'name': 'Int'},
            {'kind': 'SCALAR', 'name': 'ID'},
          ],
        },
      });

      expect(sdl, contains('schema {\n  query: Root\n}'));
      expect(sdl, contains(r'Say \"""hi\"""'));
      expect(sdl, contains('type Root implements Node {'));
      expect(sdl, contains('interface Node implements Entity {'));
      expect(
          sdl,
          contains(
              'items(first: Int = 10): [ID!]! @deprecated(reason: "Use list")'));
      expect(sdl, contains('union Any = Root'));
      expect(sdl, contains('  BLUE @deprecated'));
      expect(() => SchemaIndex.parse(sdl), returnsNormally);
    });

    test('rejects data that is not an introspection result', () {
      expect(() => introspectionToSdl({'user': null}),
          throwsA(isA<CodegenException>()));
    });
  });

  group('downloadSchema', () {
    late HttpServer server;
    late Uri url;
    late Future<void> Function(HttpRequest request) handle;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse('http://${server.address.host}:${server.port}/graphql');
      server.listen((request) async {
        await handle(request);
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('posts the introspection query with the given headers', () async {
      String? auth;
      handle = (request) async {
        auth = request.headers.value('authorization');
        final body = jsonDecode(await utf8.decodeStream(request)) as _Json;
        expect(body['query'], contains('__schema'));
        request.response.write(jsonEncode({'data': countries}));
      };

      final sdl = await downloadSchema(url,
          headers: {'Authorization': 'Bearer test-token'});

      expect(auth, 'Bearer test-token');
      expect(sdl, contains('type Country {'));
    });

    test('explains when introspection is disabled', () async {
      handle = (request) async => request.response.write(jsonEncode({
            'errors': [
              {'message': 'GraphQL introspection is not allowed'},
            ],
          }));

      await expectLater(
        downloadSchema(url),
        throwsA(isA<CodegenException>().having((e) => e.message, 'message',
            allOf(contains('not allowed'), contains('--header')))),
      );
    });

    test('explains when the URL is not a GraphQL endpoint', () async {
      handle = (request) async {
        request.response
          ..statusCode = 404
          ..write('<html>Not found</html>');
      };

      await expectLater(
        downloadSchema(url),
        throwsA(isA<CodegenException>().having((e) => e.message, 'message',
            contains('HTTP 404 without a GraphQL'))),
      );
    });

    test('gives up on a server that never answers', () async {
      handle = (request) => Future<void>.delayed(const Duration(seconds: 5));

      await expectLater(
        downloadSchema(url, timeout: const Duration(milliseconds: 100)),
        throwsA(isA<CodegenException>()
            .having((e) => e.message, 'message', contains('did not answer'))),
      );
    });

    test('explains a redirect', () async {
      handle = (request) async {
        request.response
          ..statusCode = 301
          ..headers.set('location', 'https://elsewhere.test/graphql');
      };

      await expectLater(
        downloadSchema(url),
        throwsA(isA<CodegenException>().having((e) => e.message, 'message',
            contains('https://elsewhere.test/graphql'))),
      );
    });

    test('rejects an invalid header instead of crashing', () async {
      handle = (request) async {};
      await expectLater(
        downloadSchema(url, headers: {'Authorization': 'Bearer a\nb'}),
        throwsA(isA<CodegenException>()
            .having((e) => e.message, 'message', contains('header'))),
      );
    });

    test('messages never show credentials in the URL', () async {
      await server.close(force: true);
      final secret = url.replace(userInfo: 'me:pw', query: 'token=abc');
      await expectLater(
        downloadSchema(secret),
        throwsA(isA<CodegenException>().having((e) => e.message, 'message',
            allOf(isNot(contains('pw')), isNot(contains('abc'))))),
      );
    });

    test('explains when the server cannot be reached', () async {
      await server.close(force: true);
      await expectLater(
        downloadSchema(url),
        throwsA(isA<CodegenException>()
            .having((e) => e.message, 'message', contains('Could not reach'))),
      );
    });
  });
}
