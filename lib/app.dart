import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'core/constants/app_constants.dart';
import 'core/services/auth_service.dart';
import 'core/services/session_controller.dart';
import 'core/services/theme_controller.dart';
import 'core/theme/app_theme.dart';
import 'routing/app_router.dart';

/// Root widget: wires up app-wide providers, theme, and the router.
class JvaSafetyApp extends StatelessWidget {
  const JvaSafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => AuthService()),
        // The session owns the auth-state and profile subscriptions, and is
        // disposed by the provider when the app tears down.
        ChangeNotifierProvider(
          create: (context) =>
              SessionController(authService: context.read<AuthService>()),
        ),
        // The device's own light/dark/system override — independent of
        // SessionController (available before auth resolves, not tied to
        // any signed-in uid) — see ThemeController's doc comment for why
        // this exists (Firefox's own "Theme" setting does not change what
        // prefers-color-scheme reports to a web page, only the OS setting
        // does; this gives users an in-app way around that).
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: const _RoutedApp(),
    );
  }
}

/// Owns the one [GoRouter] for the app's lifetime.
///
/// The router must outlive rebuilds: a new router starts again at its
/// initial location, so building one inside `build` sent the user back to
/// the Dashboard (and closed any open screen) every time the theme changed.
class _RoutedApp extends StatefulWidget {
  const _RoutedApp();

  @override
  State<_RoutedApp> createState() => _RoutedAppState();
}

class _RoutedAppState extends State<_RoutedApp> {
  late final GoRouter _router = appRouterFrom(context);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final textFactor = controller.textSize.factor;
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: controller.mode,
      routerConfig: _router,
      // Settings → Text size, on top of the device's own setting. Always
      // wrapped (even at 1x) so changing it never rebuilds open screens.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              media.textScaler.scale(1) * textFactor,
            ),
          ),
          child: child!,
        );
      },
    );
  }
}
