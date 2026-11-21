import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'src/cache_view.dart';
import 'src/operations_view.dart';

void main() => runApp(const GraphQLDevToolsExtension());

/// The graphql_client_flutter tab in Dart DevTools.
class GraphQLDevToolsExtension extends StatelessWidget {
  const GraphQLDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) => const DevToolsExtension(
    child: DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(icon: Icon(Icons.swap_vert), text: 'Operations'),
              Tab(icon: Icon(Icons.storage), text: 'Cache'),
            ],
          ),
          Expanded(
            child: TabBarView(children: [OperationsView(), CacheView()]),
          ),
        ],
      ),
    ),
  );
}
