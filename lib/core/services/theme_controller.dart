import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The signed-in device's own light/dark/system theme preference —
/// deliberately independent of [SessionController] and any signed-in uid:
/// unlike `activeOrganizationId` (meaningful only once a user's memberships
/// are known), a theme preference must be available from the very first
/// frame, including on the pre-auth loading/login screens, and is a
/// per-device UI convenience rather than account data.
///
/// **Why this exists at all.** [ThemeMode.system] (Flutter's default when no
/// mode is set) follows the OS's own dark/light setting — correct on mobile,
/// where flipping the OS setting is the natural way a user controls it. On
/// desktop Firefox specifically, this app's users found that Firefox's own
/// "Theme" setting (its toolbar/menu chrome) does NOT change what
/// `prefers-color-scheme` reports to a web page — only the OS-wide setting
/// does — so a user who wants this app in dark mode without changing their
/// entire OS theme had no way to do so. This controller adds an explicit,
/// in-app override that always wins over the OS/browser signal once set,
/// while still defaulting to (and offering a way back to) following the
/// system automatically.
///
/// Persisted to [SharedPreferences] under a single fixed key (not per-uid —
/// a shared device's theme choice is a property of the device/browser
/// profile, not of whichever account happens to be signed in) so the choice
/// survives an app restart. [SharedPreferences.getInstance] is async, so
/// [mode] is a synchronous in-memory cache seeded with [ThemeMode.system]
/// and updated once the persisted value loads.
class ThemeController extends ChangeNotifier {
  ThemeController({Future<SharedPreferences>? sharedPreferences})
    : _sharedPreferences =
          sharedPreferences ?? SharedPreferences.getInstance() {
    _load();
  }

  static const _key = 'themeMode';
  static const _textSizeKey = 'textSize';

  final Future<SharedPreferences> _sharedPreferences;
  ThemeMode _mode = ThemeMode.system;
  AppTextSize _textSize = AppTextSize.normal;
  bool _disposed = false;

  /// The current preference. Starts as [ThemeMode.system] until the
  /// persisted value (if any) finishes loading — a brief, harmless window
  /// where the system default is shown before a previously-saved override
  /// takes effect.
  ThemeMode get mode => _mode;

  /// How large text is drawn on this device — on top of the device's own
  /// text-size setting. See [AppTextSize].
  AppTextSize get textSize => _textSize;

  Future<void> _load() async {
    final prefs = await _sharedPreferences;
    final stored = prefs.getString(_key);
    final resolved = ThemeMode.values.firstWhere(
      (m) => m.name == stored,
      orElse: () => ThemeMode.system,
    );
    final storedSize = prefs.getString(_textSizeKey);
    final size = AppTextSize.values.firstWhere(
      (s) => s.name == storedSize,
      orElse: () => AppTextSize.normal,
    );
    if (resolved == _mode && size == _textSize) return;
    _mode = resolved;
    _textSize = size;
    _safeNotify();
  }

  /// Sets and persists the device's theme preference. Fire-and-forget on the
  /// write-through (a UI convenience, not data that must be confirmed
  /// durable before proceeding), mirroring
  /// `SessionController.setActiveOrganization`'s own persistence pattern.
  void setMode(ThemeMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _safeNotify();
    // ignore: discarded_futures
    _sharedPreferences.then((prefs) => prefs.setString(_key, mode.name));
  }

  void setTextSize(AppTextSize size) {
    if (size == _textSize) return;
    _textSize = size;
    _safeNotify();
    // ignore: discarded_futures
    _sharedPreferences.then(
      (prefs) => prefs.setString(_textSizeKey, size.name),
    );
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The app's own text-size choice (Settings → Appearance), for reading on
/// site in bright light. Multiplies the device's own text size.
enum AppTextSize {
  normal(1.0, 'Normal'),
  large(1.15, 'Large');

  const AppTextSize(this.factor, this.label);

  final double factor;
  final String label;
}
