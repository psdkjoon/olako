import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/core/edit_history.dart';
import 'package:olako/core/recent_store.dart';
import 'package:olako/core/safely.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/platform/system_service.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/settings/app_settings.dart';
import 'package:olako/ui/editor/editor_screen.dart';
import 'package:olako/ui/library_screen.dart';
import 'package:olako/ui/viewer/viewer_screen.dart';

abstract class DocumentOpener {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static RecentStore? _recents;
  static AppSettings? _settings;
  static bool _started = false;
  static const String viewerRoute = 'viewer';
  static const String editorRoute = 'editor';

  static Future<void> start(RecentStore recents, AppSettings settings) async {
    _recents = recents;
    _settings = settings;
    if (_started) return;
    _started = true;
    await EditHistory.scan();
    await recents.prune(EditHistory.pending.value);
    SystemService.onIncoming = () => unawaited(_takeIncoming());
    await _takeIncoming();
  }

  static Future<void> _takeIncoming() async {
    final incoming = await SystemService.takeIncoming();
    if (incoming == null) return;
    for (final path in incoming.files) {
      await _import(path, path.split('/').last, '', external: true);
    }
  }

  static Future<void> pick() async {
    final path = await DocumentService.pick();
    if (path == null) return;
    await _import(path, path.split('/').last, '');
  }

  static Future<void> createNote() async {
    final recents = _recents;
    final navigator = navigatorKey.currentState;
    final settings = _settings;
    if (recents == null || navigator == null || settings == null) return;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final name =
        'Note ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.${two(now.second)}.md';
    try {
      final folder = await Directory.systemTemp.createTemp('olako-new');
      final file = File('${folder.path}/$name');
      await file.writeAsString('# \n\n');
      final entry = await recents.add(
        sourcePath: file.path,
        name: name,
        kind: DocumentKind.markdown,
        fresh: true,
      );
      await safely(() => folder.delete(recursive: true));
      await navigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: editorRoute),
          builder: (_) =>
              EditorScreen(entry: entry, recents: recents, settings: settings),
        ),
      );
    } on Object {
      _say("Couldn't open this document");
    }
  }

  static void edit(RecentEntry entry) {
    final navigator = navigatorKey.currentState;
    final recents = _recents;
    final settings = _settings;
    if (navigator == null || recents == null || settings == null) return;
    if (!File(entry.path).existsSync()) {
      unawaited(recents.remove(entry.id));
      _say("Couldn't open this document");
      return;
    }
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: editorRoute),
          builder: (_) => EditorScreen(
            entry: entry,
            recents: recents,
            settings: settings,
            resume: true,
          ),
        ),
      ),
    );
  }

  static Future<void> openLibrary() async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => const LibraryScreen()),
    );
  }

  static Future<void> openFile(String path, String name) async {
    try {
      await _import(path, name, '', removeSource: false);
    } on Object {
      _say("Couldn't open this document");
    }
  }

  static Future<void> keep(String path, String name) async {
    try {
      final folder = await Directory.systemTemp.createTemp('olako-keep');
      final copy = await File(path).copy('${folder.path}/$name');
      await _import(copy.path, name, '');
      await safely(() => folder.delete(recursive: true));
    } on Object {
      _say("Couldn't open this document");
    }
  }

  static Future<void> _import(
    String path,
    String name,
    String mime, {
    bool removeSource = true,
    bool external = false,
  }) async {
    final recents = _recents;
    if (recents == null) return;
    final kind = detectKind(name, mime) ?? await sniffKind(path);
    if (kind == null) {
      if (removeSource) await safely(() => File(path).delete());
      _say('This kind of file cannot be opened.');
      return;
    }
    final entry = await recents.add(
      sourcePath: path,
      name: name,
      kind: kind,
      removeSource: removeSource,
    );
    show(entry, external: external);
  }

  static void openRecent(RecentEntry entry) {
    if (!File(entry.path).existsSync()) {
      unawaited(_recents?.remove(entry.id));
      _say("Couldn't open this document");
      return;
    }
    _recents?.touch(entry.id);
    show(entry);
  }

  static void show(RecentEntry entry, {bool external = false}) {
    final navigator = navigatorKey.currentState;
    final recents = _recents;
    final settings = _settings;
    if (navigator == null || recents == null || settings == null) return;
    if (external) {
      navigator.popUntil(
        (r) =>
            r.isFirst ||
            (r.settings.name != viewerRoute && r.settings.name != editorRoute),
      );
    }
    final pushed = navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: viewerRoute),
        builder: (_) =>
            ViewerScreen(entry: entry, recents: recents, settings: settings),
      ),
    );
    if (!external) {
      unawaited(pushed);
      return;
    }
    unawaited(
      pushed.then((_) {
        if (!navigator.canPop()) unawaited(SystemService.closeApp());
      }),
    );
  }

  static void _say(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
