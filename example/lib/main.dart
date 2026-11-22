// A complete app: countries from a public GraphQL API, with an offline
// cache, pull-to-refresh, loading and error states.
//
// The API (https://countries.trevorblades.com) needs no key. The query lives
// in lib/countries.graphql; `dart run graphql_client_flutter:generate` turns
// it into typed Dart (lib/countries.graphql.dart).

import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'countries.graphql.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = GraphQLClient(
    'https://countries.trevorblades.com/graphql',
    // Keeps results on disk so the list shows instantly and offline.
    cache: GraphQLCache(
      store: await PersistentStore.open(),
      // Keeps the cache small: the least recently used objects go first.
      maxEntities: 2000,
      // Countries are identified by `code`, not `id`.
      typePolicies: {
        'Country': const TypePolicy(keyFields: {'code': true}),
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
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFFE10098)),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFFE10098),
      brightness: Brightness.dark,
    ),
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
  String continent = 'EU';

  @override
  Widget build(BuildContext context) {
    // Changing `variables` loads the new continent automatically.
    return GraphQLQuery<CountriesData>(
      document: countriesDocument,
      variables: countriesVariables(continent: continent),
      parse: CountriesData.fromJson,
      builder: (context, state, query) => Scaffold(
        appBar: AppBar(
          title: const Text('Countries'),
          actions: [
            if (state case QueryData(:final source))
              _SourceBadge(source: source),
            const SizedBox(width: 12),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
        ),
        body: switch (state) {
          QueryLoading() => const Center(child: CircularProgressIndicator()),
          QueryData(:final data) => RefreshIndicator(
            onRefresh: query.refetch,
            child: ListView.separated(
              itemCount: data.countries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _CountryTile(data.countries[i]),
            ),
          ),
          QueryError(:final exception) => _ErrorView(
            message: exception.userMessage,
            onRetry: query.refetch,
          ),
        },
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile(this.country);

  final CountriesData$Countries country;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Text(country.emoji, style: const TextStyle(fontSize: 30)),
    title: Text(country.name),
    subtitle: Text(country.capital ?? 'No capital'),
    trailing: Text(
      country.currency?.split(',').first ?? '',
      style: Theme.of(context).textTheme.labelLarge,
    ),
  );
}

/// Shows whether the list came from the network or the offline cache.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final ResultSource source;

  @override
  Widget build(BuildContext context) {
    final live = source == ResultSource.network;
    return Chip(
      avatar: Icon(live ? Icons.cloud_done : Icons.offline_bolt, size: 18),
      label: Text(live ? 'Live' : 'Cached'),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<Object?> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 48),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
