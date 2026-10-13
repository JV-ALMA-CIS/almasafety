import 'package:flutter/material.dart';
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
      child: Builder(
        builder: (context) {
          final router = appRouterFrom(context);
          final themeMode = context.watch<ThemeController>().mode;
          return MaterialApp.router(
            title: AppConstants.appName,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeMode,
            routerConfig: router,
          );
        },
      ),
    );
  }
}
