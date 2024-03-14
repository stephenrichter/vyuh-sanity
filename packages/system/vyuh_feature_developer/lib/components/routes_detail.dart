import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart' as g;
import 'package:go_router/go_router.dart';
import 'package:vyuh_core/vyuh_core.dart';

class RoutesList extends StatefulWidget {
  final FeatureDescriptor feature;
  const RoutesList({super.key, required this.feature});

  @override
  State<RoutesList> createState() => _RoutesListState();
}

class _RoutesListState extends State<RoutesList> {
  late final Future<List<_PathInfo>> _paths;

  @override
  void initState() {
    super.initState();

    _paths = _fetchRoutes();
  }

  // The return-type is necessary here otherwise Dart will treat this as
  // as Future<dynamic> and cause a CastException
  Future<List<_PathInfo>> _fetchRoutes() async {
    final routes = await widget.feature.routes?.call();

    final List<_PathInfo> paths = [];
    if (routes != null) {
      _recurse(routes, paths, '', 0);
    }

    return paths;
  }

  _recurse(List<g.RouteBase> routes, List<_PathInfo> accumulator,
      String parentPath, int depth) {
    for (final route in routes) {
      String prefix = parentPath;

      if (route is g.GoRoute) {
        final path = '''${depth == 0 ? '' : '$parentPath/'}${route.path}''';

        prefix = path;
        accumulator.add((path, depth));
      }

      if (route.routes.isNotEmpty) {
        final actualDepth = route is ShellRouteBase ? depth : depth + 1;
        _recurse(route.routes, accumulator, prefix, actualDepth);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _paths,
      builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          final paths = snapshot.data!;
          return SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: _PathList(paths: paths),
          );
        } else {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
      },
    );
  }
}

typedef _PathInfo = (String path, int depth);

class _PathList extends StatelessWidget {
  final List<_PathInfo> paths;

  const _PathList({required this.paths});

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemBuilder: (_, index) {
        final path = paths[index];

        return Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            SizedBox(width: path.$2 * 10),
            if (path.$2 > 0)
              Transform.flip(
                  flipY: true, child: const Icon(Icons.turn_right_rounded)),
            Expanded(
              child: Text(
                path.$1,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.apply(fontFamily: 'Courier'),
              ),
            ),
          ],
        );
      },
      itemCount: paths.length,
    );
  }
}
