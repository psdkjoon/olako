import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:olako/platform/desktop_theme_store.dart';
import 'package:olako/settings/app_settings.dart';

abstract class ThemeSyncService {
  static const _channel = MethodChannel('olako/theme_sync');
  static AppSettings? _settings;
  static Future<void> _queue = Future.value();
  static String? _sent;
  static bool _wasEnabled = false;

  static bool get _desktop => Platform.isLinux || Platform.isWindows;

  static bool get supported => Platform.isAndroid || _desktop;

  static Future<void> adoptStored(AppSettings settings) async {
    if (!supported || !settings.syncAppearance) return;
    if (_desktop) {
      if (_adopt(settings, DesktopThemeStore.read())) await settings.flush();
      return;
    }
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('current');
      _adopt(settings, state);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> init(AppSettings settings) {
    if (!supported || _settings != null) return Future.value();
    _settings = settings;
    _wasEnabled = settings.syncAppearance;
    if (_desktop) {
      DesktopThemeStore.watch(() => unawaited(_run(pull: true)));
    } else {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'refresh') await _run(pull: false);
        return null;
      });
    }
    settings.addListener(_onSettings);
    WidgetsBinding.instance.addObserver(_ResumeObserver());
    return _run(pull: true);
  }

  static String _key(AppSettings s) =>
      '${s.syncAppearance}|${s.accent}|${s.themeMode.name}|${s.appearanceUpdatedAt}';

  static void _onSettings() {
    final settings = _settings;
    if (settings == null) return;
    final key = _key(settings);
    if (key == _sent) return;
    final turnedOn = settings.syncAppearance && !_wasEnabled;
    _wasEnabled = settings.syncAppearance;
    unawaited(_run(pull: turnedOn));
  }

  static Future<void> _run({required bool pull}) {
    return _queue = _queue.then((_) => _sync(pull: pull));
  }

  static Future<void> _sync({required bool pull}) async {
    final settings = _settings;
    if (settings == null) return;
    if (_desktop) {
      _sent = _key(settings);
      final state = DesktopThemeStore.publish(
        enabled: settings.syncAppearance,
        accent: settings.accent,
        mode: settings.themeMode.name,
        updatedAt: settings.appearanceUpdatedAt,
      );
      if (_adopt(settings, state)) await settings.flush();
      _sent = _key(settings);
      return;
    }
    try {
      _sent = _key(settings);
      var state = await _channel.invokeMapMethod<String, Object?>('publish', {
        'enabled': settings.syncAppearance,
        'accent': settings.accent,
        'mode': settings.themeMode.name,
        'updatedAt': settings.appearanceUpdatedAt,
      });
      var changed = _adopt(settings, state);
      if (pull && settings.syncAppearance) {
        state =
            await _channel.invokeMapMethod<String, Object?>('pull') ?? state;
        changed = _adopt(settings, state) || changed;
      }
      if (changed) await settings.flush();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  static bool _adopt(AppSettings settings, Map<String, Object?>? state) {
    if (state == null || !settings.syncAppearance) return false;
    final accent = state['accent'];
    final updatedAt = state['updatedAt'];
    if (accent is! String || updatedAt is! num) return false;
    final mode = state['mode'];
    if (updatedAt.toInt() <= settings.appearanceUpdatedAt) return false;
    settings.adoptAppearance(
      accent,
      mode is String ? mode : null,
      updatedAt.toInt(),
    );
    return true;
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ThemeSyncService._run(pull: true));
    }
  }
}
