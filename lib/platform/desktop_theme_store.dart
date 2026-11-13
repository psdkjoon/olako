import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract class DesktopThemeStore {
  static const _vendor = 'ir.psdkjoon';
  static const _fileName = 'theme_sync.json';
  static const _modes = {'system', 'light', 'dark'};
  static const _settle = Duration(milliseconds: 150);
  static const _retryAfter = Duration(seconds: 5);

  static StreamSubscription<FileSystemEvent>? _subscription;
  static Timer? _debounce;
  static Timer? _retry;

  static Directory? _directory() {
    final env = Platform.environment;
    final String? base;
    if (Platform.isWindows) {
      base = env['APPDATA'];
    } else if (Platform.isLinux) {
      final config = env['XDG_CONFIG_HOME'];
      final home = env['HOME'];
      if (config != null && config.isNotEmpty) {
        base = config;
      } else if (home != null && home.isNotEmpty) {
        base = '$home/.config';
      } else {
        base = null;
      }
    } else {
      base = null;
    }
    if (base == null || base.isEmpty) return null;
    return Directory('$base${Platform.pathSeparator}$_vendor');
  }

  static File? _file() {
    final dir = _directory();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Map<String, Object?>? _clean(Object? decoded) {
    if (decoded is! Map) return null;
    final Object? accent = decoded['accent'];
    final Object? mode = decoded['mode'];
    final Object? updatedAt = decoded['updatedAt'];
    if (accent is! String || !RegExp(r'^[a-z]+$').hasMatch(accent)) return null;
    if (updatedAt is! num) return null;
    final stamp = updatedAt.toInt();
    final limit = DateTime.now().millisecondsSinceEpoch + 86400000;
    if (stamp <= 0 || stamp > limit) return null;
    return {
      'accent': accent,
      'mode': mode is String && _modes.contains(mode) ? mode : 'system',
      'updatedAt': stamp,
    };
  }

  static Map<String, Object?>? read() {
    final file = _file();
    if (file == null) return null;
    try {
      return _clean(jsonDecode(file.readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?>? publish({
    required bool enabled,
    required String accent,
    required String mode,
    required int updatedAt,
  }) {
    final file = _file();
    if (file == null || !enabled) return null;
    final current = read();
    final known = current?['updatedAt'];
    final candidate = _clean({
      'accent': accent,
      'mode': mode,
      'updatedAt': updatedAt,
    });
    if (candidate == null) return current;
    if (known is int && updatedAt <= known) return current;
    try {
      file.parent.createSync(recursive: true);
    } on FileSystemException {
      return current;
    }
    return _write(file, candidate) ? candidate : current;
  }

  static bool _write(File file, Map<String, Object?> state) {
    final text = jsonEncode(state);
    final temp = File('${file.path}.$pid.tmp');
    try {
      temp.writeAsStringSync(text, flush: true);
      temp.renameSync(file.path);
      return true;
    } on FileSystemException {
      _discard(temp);
    }
    try {
      file.writeAsStringSync(text, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static void _discard(File file) {
    try {
      file.deleteSync();
    } on FileSystemException {
      return;
    }
  }

  static void watch(void Function() onChange) {
    final dir = _directory();
    if (dir == null || _subscription != null) return;
    try {
      dir.createSync(recursive: true);
      _subscription = dir.watch().listen((_) {
        _debounce?.cancel();
        _debounce = Timer(_settle, onChange);
      }, onError: (Object _) => _restart(onChange));
    } on FileSystemException {
      _restart(onChange);
    }
  }

  static void _restart(void Function() onChange) {
    stop();
    _retry = Timer(_retryAfter, () => watch(onChange));
  }

  static void stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _debounce?.cancel();
    _retry?.cancel();
  }
}
