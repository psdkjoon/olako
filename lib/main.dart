import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:olako/app.dart';
import 'package:olako/core/diagnostics.dart';
import 'package:olako/core/kv_store.dart';
import 'package:olako/core/recent_store.dart';
import 'package:olako/platform/launcher_icon_service.dart';
import 'package:olako/platform/theme_sync_service.dart';
import 'package:olako/settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diagnostics.init();

  final store = await KvStore.open();
  final settings = AppSettings.load(store);

  await ThemeSyncService.adoptStored(settings);

  final recents = RecentStore.load(store);

  runApp(OlakoApp(settings: settings, recents: recents));

  unawaited(_initPlatform(settings));
}

Future<void> _initPlatform(AppSettings settings) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } on Object {
    debugPrint('edge-to-edge unavailable');
  }

  LauncherIconService.init(settings);
  await ThemeSyncService.init(settings);
}
