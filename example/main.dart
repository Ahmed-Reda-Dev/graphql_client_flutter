// A complete app in one file: a list of countries from a public GraphQL API,
// with offline cache, pull-to-refresh and error handling.
//
// The API (https://countries.trevorblades.com) needs no key.

import 'package:flutter/material.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

const countriesQuery = r'''
  query Countries($continent: String!) {
    countries(filter: { continent: { eq: $continent } }) {
      code
      name
      emoji
      capital
    }
  }
''';

/// An app-level model: `parse` turns raw JSON into these.
class Country {
  const Country({
    required this.code,
    required this.name,
    required this.emoji,
    this.capital,
  });

  factory Country.fromJson(JsonMap json) => Country(
        code: json['code'] as String,
        name: json['name'] as String,
        emoji: json['emoji'] as String,
        capital: json['capital'] as String?,
      );

  final String code;
  final String name;
  final String emoji;
  final String? capital;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = GraphQLClient(
    'https://countries.trevorblades.com/graphql',
    // Keeps results on disk so the list shows instantly and offline.
    cache: GraphQLCache(
      store: await PersistentStore.open(),
      // Countries are identified by `code`, not `id`.
      typePolicies: {
        'Country': const TypePolicy(keyFields: {'code': true})
      },
    ),
    logging: true,
  );

  runApp(GraphQLProvider(client: client, child: const CountriesApp()));
}

class CountriesApp extends StatelessWidget {
  const CountriesApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Countries',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const CountriesPage(),
      );
}

class CountriesPage extends StatefulWidget {
  const CountriesPage({super.key});

  @override
  State<CountriesPage> createState() => _CountriesPageState();
}

class _CountriesPageState extends State<CountriesPage> {
  static const continents = {'AF': 'Africa', 'EU': 'Europe', 'AS': 'Asia'};
  String continent = 'AF';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Countries'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: SegmentedButton<String>(
            segments: [
              for (final MapEntry(:key, :value) in continents.entries)
                ButtonSegment(value: key, label: Text(value)),
            ],
            selected: {continent},
            onSelectionChanged: (s) => setState(() => continent = s.first),
          ),
        ),
      ),
      // Changing `variables` loads the new continent automatically.
      body: GraphQLQuery<List<Country>>(
        document: countriesQuery,
        variables: {'continent': continent},
        parse: (data) => (data['countries'] as List)
            .map((c) => Country.fromJson(c as JsonMap))
            .toList(),
        builder: (context, state, query) => switch (state) {
          QueryLoading() => const Center(child: CircularProgressIndicator()),
          QueryData(:final data) => RefreshIndicator(
              onRefresh: query.refetch,
              child: ListView.builder(
                itemCount: data.length,
                itemBuilder: (context, i) => ListTile(
                  leading:
                      Text(data[i].emoji, style: const TextStyle(fontSize: 28)),
                  title: Text(data[i].name),
                  subtitle: Text(data[i].capital ?? '—'),
                ),
              ),
            ),
          QueryError(:final exception) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(exception.userMessage, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: query.refetch,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
        },
      ),
    );
  }
}
