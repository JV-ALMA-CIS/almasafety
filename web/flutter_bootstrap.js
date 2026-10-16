{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: Flutter's own worker is only a stub that
// unregisters itself, and would replace offline_sw.js (see index.html).
_flutter.loader.load();
