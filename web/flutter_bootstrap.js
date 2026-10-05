{{flutter_js}}
{{flutter_build_config}}

// Recall registers its versioned sw.js after load. Asking Flutter to prepare
// its retired worker would replace that registration with a missing tombstone.
_flutter.loader.load();
