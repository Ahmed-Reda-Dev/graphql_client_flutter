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
is generated from the schema in [lib/graphql](lib/graphql); after editing
the query, run:

```bash
dart run graphql_client_flutter:generate
```

The API ([countries.trevorblades.com](https://countries.trevorblades.com))
needs no key.
