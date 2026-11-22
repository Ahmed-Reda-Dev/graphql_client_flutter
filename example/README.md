# graphql_client_flutter example

A complete app ([lib/main.dart](lib/main.dart)): countries from a public
GraphQL API, with a persistent offline cache, pull-to-refresh, loading and
error states.

```bash
cd example
flutter run
```

The query lives in [lib/countries.graphql](lib/countries.graphql). The
typed Dart it uses ([lib/countries.graphql.dart](lib/countries.graphql.dart))
is generated from the schema in [lib/graphql](lib/graphql). After editing
the query, run (add `--watch` to regenerate on every save):

```bash
dart run graphql_client_flutter:generate
```

To refresh the schema from the API (`schema_url` in pubspec.yaml):

```bash
dart run graphql_client_flutter:generate --download
```

The API ([countries.trevorblades.com](https://countries.trevorblades.com))
needs no key.
