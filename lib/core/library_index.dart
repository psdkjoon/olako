import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:olako/core/app_dirs.dart';
import 'package:olako/core/safely.dart';
import 'package:olako/platform/document_service.dart';

class LibraryIndex extends ChangeNotifier {
  LibraryIndex._();

  static final LibraryIndex instance = LibraryIndex._();

  List<LibraryFile> _files = const <LibraryFile>[];
  bool _loaded = false;
  bool _scanning = false;
  bool _denied = false;
  bool _started = false;
  int _scannedAt = 0;

  List<LibraryFile> get files => _files;
  bool get loaded => _loaded;
  bool get scanning => _scanning;
  bool get denied => _denied;
  int get scannedAt => _scannedAt;

  Future<File> _cacheFile() async =>
      File('${await AppDirs.data()}/library.json');

  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    await _readCache();
    await refresh();
  }

  Future<void> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final rows = decoded['f'];
      final out = <LibraryFile>[];
      if (rows is List) {
        for (final row in rows) {
          if (row is! List || row.length < 4) continue;
          final path = row[0];
          final name = row[1];
          final size = row[2];
          final modified = row[3];
          if (path is! String ||
              name is! String ||
              size is! num ||
              modified is! num) {
            continue;
          }
          out.add(
            LibraryFile(
              path: path,
              name: name,
              size: size.toInt(),
              modified: modified.toInt(),
            ),
          );
        }
      }
      final stamp = decoded['t'];
      _scannedAt = stamp is num ? stamp.toInt() : 0;
      _files = out;
      _loaded = out.isNotEmpty;
      notifyListeners();
    } on Object {
      return;
    }
  }

  Future<void> refresh() async {
    if (_scanning) return;
    final granted = await DocumentService.storageGranted();
    _denied = !granted;
    if (!granted) {
      _loaded = true;
      notifyListeners();
      return;
    }
    _scanning = true;
    notifyListeners();
    final fresh = await DocumentService.scan();
    fresh.sort((a, b) => b.modified.compareTo(a.modified));
    _files = fresh;
    _loaded = true;
    _scanning = false;
    _scannedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    unawaited(_writeCache(fresh));
  }

  Future<void> _writeCache(List<LibraryFile> files) async {
    await safely(() async {
      final file = await _cacheFile();
      final rows = <List<Object>>[
        for (final f in files) <Object>[f.path, f.name, f.size, f.modified],
      ];
      await file.writeAsString(
        jsonEncode(<String, Object>{'t': _scannedAt, 'f': rows}),
        flush: true,
      );
    });
  }
}
