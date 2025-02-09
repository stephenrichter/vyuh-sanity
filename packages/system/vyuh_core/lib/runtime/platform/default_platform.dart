part of '../run_app.dart';

class _PluginInstanceCache {
  final Set<Plugin> _plugins = {};

  _PluginInstanceCache();

  final Map<Type, Plugin?> _pluginsMap = {};

  T? getPlugin<T extends Plugin>() {
    if (_pluginsMap.containsKey(T)) {
      return _pluginsMap[T] as T?;
    }

    final plugin = _plugins.firstWhereOrNull((final plugin) => plugin is T);

    _pluginsMap[T] = plugin;

    return plugin as T?;
  }

  /// Add Items to List.
  ///
  /// NOTE: This remove the Lookup cache.
  void addAll(Iterable<Plugin> plugins) {
    _plugins.addAll(plugins);
    _pluginsMap.clear();
  }

  // Get the list
  List<Plugin> get items => List.unmodifiable(_plugins);
}

final class _DefaultVyuhPlatform extends VyuhPlatform {
  final _PluginInstanceCache _plugins = _PluginInstanceCache();

  final Map<Type, ExtensionBuilder> _featureExtensionBuilderMap = {};

  /// Initialize first time to avoid any late-init errors.
  /// Eventually this will be initialized anytime we restart the platform
  GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

  late final SystemInitTracker _tracker;

  String _userInitialLocation = '/';

  /// The initial Location that will be used by the router
  final String? initialLocation;

  @override
  GlobalKey<NavigatorState> get rootNavigatorKey => _rootNavigatorKey;

  @override
  SystemInitTracker get tracker => _tracker;

  List<FeatureDescriptor> _features = [];

  @override
  List<vc.FeatureDescriptor> get features => _features;

  final Map<String, Future<void>> _readyFeatures = {};

  @override
  Future<void>? featureReady(String featureName) => _readyFeatures[featureName];

  @override
  final FeaturesBuilder featuresBuilder;

  @override
  List<Plugin> get plugins => _plugins.items;

  @override
  final PlatformWidgetBuilder widgetBuilder;

  _DefaultVyuhPlatform({
    required this.featuresBuilder,
    required PluginDescriptor pluginDescriptor,
    required this.widgetBuilder,
    this.initialLocation,
  }) {
    _plugins.addAll(pluginDescriptor.plugins);

    _tracker = _PlatformInitTracker(this);

    reaction((_) => _tracker.currentState.value == InitState.notStarted,
        (notStarted) {
      if (notStarted) {
        // Ensure the navigator key is established everytime the system is restarted
        // This avoids the error of a duplicate GlobalKey across GoRouter instances
        _rootNavigatorKey = GlobalKey<NavigatorState>();
      }
    });
  }

  @override
  Future<void> run() async {
    final preLoadedPlugins = plugins.whereType<vc.PreloadedPlugin>();

    for (final plugin in preLoadedPlugins) {
      await plugin.init();
    }

    _userInitialLocation = PlatformDispatcher.instance.defaultRouteName;

    flutter.runApp(const _FrameworkInitView());
  }

  @override
  Future<void> initPlugins(vc.Trace parentTrace) => telemetry.trace(
      name: 'Plugins',
      operation: 'Init',
      parentTrace: parentTrace,
      fn: (trace) async {
        // Run a cleanup first
        final disposeFns = plugins.map((e) => e.dispose());
        await Future.wait(disposeFns, eagerError: true);

        // Check
        final initFns = plugins.map((e) {
          return telemetry.trace<void>(
            name: 'Plugin: ${e.title}',
            operation: 'Init',
            parentTrace: trace,
            fn: (_) => e.init(),
          );
        });

        await Future.wait(initFns, eagerError: true);
      });

  @override
  Future<void> initFeatures(vc.Trace parentTrace) async {
    // Run a cleanup first
    final disposeFns =
        _features.where((e) => e.dispose != null).map((e) => e.dispose!());
    await Future.wait(disposeFns, eagerError: true);

    return telemetry.trace<void>(
      name: 'Features',
      operation: 'Init',
      parentTrace: parentTrace,
      fn: (trace) async {
        _readyFeatures.clear();
        _features = await featuresBuilder();

        final initFns =
            _features.map((feature) => telemetry.trace<List<g.RouteBase>>(
                  name: 'Feature: ${feature.title}',
                  operation: 'Init',
                  parentTrace: trace,
                  fn: (trace) {
                    final future = _initFeature(feature, trace);

                    _readyFeatures[feature.name] = future;

                    return future;
                  },
                ));

        final allRoutes = await Future.wait(initFns, eagerError: true);
        _initRouter(
          allRoutes
              .where((routes) => routes != null)
              .cast<List<g.RouteBase>>()
              .expand((routes) => routes)
              .toList(),
        );

        _initFeatureExtensions(_features);
      },
    );
  }

  Future<List<g.RouteBase>> _initFeature(
      FeatureDescriptor feature, vc.Trace? parentTrace) async {
    await feature.init?.call();

    if (feature.routes == null) {
      return [];
    }

    final featureRoutes = await telemetry.trace<List<g.RouteBase>>(
      name: 'Routes: ${feature.title}',
      operation: 'Init',
      parentTrace: parentTrace,
      fn: (_) => feature.routes!(),
    );

    return featureRoutes ?? [];
  }

  Future<void> _initRouter(List<g.RouteBase> routes) async {
    router.initRouter(
      routes: routes,
      initialLocation: _userInitialLocation == '/'
          ? initialLocation ?? '/'
          : _userInitialLocation,
      rootNavigatorKey: _rootNavigatorKey,
    );
  }

  void _initFeatureExtensions(List<FeatureDescriptor> featureList) {
    // Run a cleanup first
    _features
        .expand((e) => e.extensionBuilders ?? <vc.ExtensionBuilder>[])
        .forEach((e) => e.dispose());

    final builders = featureList
        .expand((element) => element.extensionBuilders ?? <ExtensionBuilder>[])
        .groupListsBy((element) => element.extensionType);

    for (final entry in builders.entries) {
      assert(entry.value.length == 1,
          'There can be only one FeatureExtensionBuilder for a schema-type. We found ${entry.value.length} for ${entry.key}');

      _featureExtensionBuilderMap[entry.key] = entry.value.first;
    }

    final extensions = featureList
        .expand((element) => element.extensions ?? <ExtensionDescriptor>[])
        .groupListsBy((element) => element.runtimeType);

    extensions.forEach((runtimeType, descriptors) {
      final builder = _featureExtensionBuilderMap[runtimeType];

      assert(builder != null,
          'Missing FeatureExtensionBuilder for FeatureExtensionDescriptor of schemaType: $runtimeType');

      builder?.init(descriptors);
    });
  }

  @override
  T? getPlugin<T extends vc.Plugin>() => _plugins.getPlugin<T>();
}

final class RoutingConfigNotifier extends ValueNotifier<g.RoutingConfig> {
  RoutingConfigNotifier(List<g.RouteBase> routes)
      : super(g.RoutingConfig(routes: routes));

  void setRoutes(List<g.RouteBase> routes) {
    value = g.RoutingConfig(routes: routes);
  }
}
