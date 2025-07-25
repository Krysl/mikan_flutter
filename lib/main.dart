import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ff_annotation_route_library/ff_annotation_route_library.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:jiffy/jiffy.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'firebase_options.dart';
import 'internal/dynamic_color.dart';
import 'internal/extension.dart';
import 'internal/hive.dart';
import 'internal/http_cache_manager.dart';
import 'internal/lifecycle.dart';
import 'internal/log.dart';
import 'internal/method.dart';
import 'internal/network_font_loader.dart';
import 'mikan_route.dart';
import 'mikan_routes.dart';
import 'providers/fonts_model.dart';
import 'providers/home_model.dart';
import 'providers/index_model.dart';
import 'providers/list_model.dart';
import 'providers/op_model.dart';
import 'providers/subscribed_model.dart';
import 'topvars.dart';
import 'widget/loading.dart';
import 'widget/restart.dart';
import 'widget/toast.dart';

final _analytics = FirebaseAnalytics.instance;
final _observer = FirebaseAnalyticsObserver(analytics: _analytics);

final isMobile = Platform.isIOS || Platform.isAndroid;
final isSupportFirebase = isMobile || Platform.isMacOS;
final isDesktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Jiffy.setLocale('zh_cn');
  await _initMisc();
  await _initWindow();
  runApp(Restart(child: const MikanApp()));
}

Future<void> _initWindow() async {
  if (isDesktop) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      minimumSize: Size(480, 320),
      title: 'MikanProject',
    );
    unawaited(
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  }
}

Future _initFirebase() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FirebaseCrashlytics.instance
      .setCrashlyticsCollectionEnabled(kDebugMode);
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
}

Future<void> _initMisc() async {
  await Future.wait([
    MyHive.init(),
    if (isSupportFirebase) _initFirebase(),
  ]);
  NetworkFontLoader.init();
  HttpCacheManager.init();
  if (Platform.isAndroid) {
    unawaited(
      FlutterDisplayMode.setHighRefreshRate().catchError((e, s) {
        e.error(stackTrace: s);
      }),
    );
  }
}

class MikanApp extends StatefulWidget {
  const MikanApp({super.key});

  @override
  State<MikanApp> createState() => _MikanAppState();
}

class _MikanAppState extends State<MikanApp> {
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = Connectivity().onConnectivityChanged.listen((result) {
      // This condition is for demo purposes only to explain every connection type.
      // Use conditions which work for your requirements.
      if (result.contains(ConnectivityResult.mobile)) {
        // Mobile network available.
        '正在使用 移动网络'.toast();
      } else if (result.contains(ConnectivityResult.wifi)) {
        // Wi-fi is available.
        // Note for Android:
        // When both mobile and Wi-Fi are turned on system will return Wi-Fi only as active network type
        '正在使用 WiFi网络'.toast();
      } else if (result.contains(ConnectivityResult.ethernet)) {
        // Ethernet connection available.
        '正在使用 以太网'.toast();
      } else if (result.contains(ConnectivityResult.vpn)) {
        // Vpn connection active.
        // Note for iOS and macOS:
        // There is no separate network interface type for [vpn].
        // It returns [other] on any device (also simulator)
        '正在使用 VPN'.toast();
      } else if (result.contains(ConnectivityResult.bluetooth)) {
        // Bluetooth connection available.
        '正在使用 蓝牙网络'.toast();
      } else if (result.contains(ConnectivityResult.other)) {
        // Connected to a network which is not in the above mentioned networks.
        '正在使用 未知网络'.toast();
      } else if (result.contains(ConnectivityResult.none)) {
        // No available network types
        '网络已断开'.toast();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<FontsModel>(
          create: (context) => FontsModel(),
          lazy: false,
        ),
        ChangeNotifierProvider<SubscribedModel>(
          create: (_) => SubscribedModel(),
        ),
        ChangeNotifierProvider<OpModel>(
          create: (_) => OpModel(),
        ),
        ChangeNotifierProvider<IndexModel>(
          create: (context) => IndexModel(context.read<SubscribedModel>()),
          lazy: false,
        ),
        ChangeNotifierProvider<ListModel>(
          create: (_) => ListModel(),
        ),
        ChangeNotifierProvider<HomeModel>(
          create: (_) => HomeModel(),
        ),
      ],
      child: _buildMaterialApp(context),
    );
  }

  Widget _buildMaterialApp(BuildContext context) {
    return ThemeProvider(
      builder: (mode, lightColorScheme, darkColorScheme, fontFamily) {
        final navigatorObservers = [
          Lifecycle.lifecycleRouteObserver,
          FlutterSmartDialog.observer,
          if (isSupportFirebase) _observer,
          FFNavigatorObserver(
            routeChange: (newRoute, oldRoute) {
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
              //you can track page here
              final oldSettings = oldRoute?.settings;
              final newSettings = newRoute?.settings;
              'route change: '
                      '${oldSettings?.name} => ${newSettings?.name}'
                  .$debug();
            },
          ),
        ];
        return MaterialApp(
          scrollBehavior: const AlwaysStretchScrollBehavior(),
          themeMode: mode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            fontFamily: fontFamily,
            colorScheme: lightColorScheme,
            visualDensity: VisualDensity.standard,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            colorScheme: darkColorScheme,
            visualDensity: VisualDensity.standard,
          ),
          initialRoute: Routes.splash.name,
          builder: FlutterSmartDialog.init(
            toastBuilder: (msg) => ToastWidget(msg: msg),
            loadingBuilder: (msg) => LoadingWidget(msg: msg),
            builder: (context, child) => GestureDetector(
              onTap: hideKeyboard,
              child: child,
            ),
          ),
          onGenerateRoute: (RouteSettings settings) {
            return onGenerateRoute(
              settings: settings,
              getRouteSettings: getRouteSettings,
            );
          },
          navigatorKey: navKey,
          navigatorObservers: navigatorObservers,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN')],
        );
      },
    );
  }
}

class ThemeProvider extends StatefulWidget {
  const ThemeProvider({super.key, required this.builder});

  final Widget Function(
    ThemeMode mode,
    ColorScheme lightColorScheme,
    ColorScheme darkColorScheme,
    String? fontFamily,
  ) builder;

  @override
  State<ThemeProvider> createState() => _ThemeProviderState();
}

class _ThemeProviderState extends LifecycleAppState<ThemeProvider> {
  final _colorSchemePair = ValueNotifier<ColorSchemePair?>(null);

  @override
  void initState() {
    super.initState();
    _tryGetDynamicColor();
  }

  void _tryGetDynamicColor() {
    getDynamicColorScheme().then((value) {
      _colorSchemePair.value = value;
      if (MyHive.dynamicColorEnabled() && value == null) {
        MyHive.enableDynamicColor(false);
      }
    });
  }

  @override
  void onResume() {
    _tryGetDynamicColor();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _colorSchemePair,
      builder: (context, pair, child) {
        return ValueListenableBuilder(
          valueListenable: MyHive.settings.listenable(
            keys: [
              SettingsHiveKey.fontFamily,
              SettingsHiveKey.themeMode,
              SettingsHiveKey.dynamicColor,
              SettingsHiveKey.colorSeed,
            ],
          ),
          builder: (context, _, child) {
            final fontFamily = MyHive.getFontFamily()?.value;
            final themeMode = MyHive.getThemeMode();
            final dynamicColorEnabled = MyHive.dynamicColorEnabled();
            if (dynamicColorEnabled && pair != null) {
              return widget.builder.call(
                themeMode,
                pair.light,
                pair.dark,
                fontFamily,
              );
            }
            final colorSeed = Color(MyHive.getColorSeed());
            return widget.builder.call(
              themeMode,
              ColorScheme.fromSeed(seedColor: colorSeed),
              ColorScheme.fromSeed(
                seedColor: colorSeed,
                brightness: Brightness.dark,
              ),
              fontFamily,
            );
          },
        );
      },
    );
  }
}

class AlwaysStretchScrollBehavior extends ScrollBehavior {
  const AlwaysStretchScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();

  @override
  TargetPlatform getPlatform(BuildContext context) => TargetPlatform.android;

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      clipBehavior: details.decorationClipBehavior ?? Clip.hardEdge,
      child: child,
    );
  }
}
