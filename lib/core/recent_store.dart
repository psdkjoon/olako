import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:olako/core/app_dirs.dart';
import 'package:olako/core/edit_history.dart';
import 'package:olako/core/kv_store.dart';
import 'package:olako/core/safely.dart';
import 'package:olako/reader/document_loader.dart';

class RecentEntry {
  const RecentEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.openedAt,
    this.position = 0,
    this.progress = 0,
    this.owned = true,
    this.pinned = false,
    this.fresh = false,
  });

  factory RecentEntry.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    return RecentEntry(
      id: '${json['id']}',
      name: '${json['name']}',
      path: '${json['path']}',
      kind: DocumentKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => DocumentKind.markdown,
      ),
      size: (json['size'] is num) ? (json['size']! as num).toInt() : 0,
      openedAt: (json['openedAt'] is num)
          ? (json['openedAt']! as num).toInt()
          : 0,
      position: (json['pos'] is num) ? (json['pos']! as num).toDouble() : 0,
      progress: (json['progress'] is num)
          ? (json['progress']! as num).toDouble()
          : 0,
      owned: json['owned'] != false,
      pinned: json['pinned'] == true,
      fresh: json['fresh'] == true,
    );
  }

  final String id;
  final String name;
  final String path;
  final DocumentKind kind;
  final int size;
  final int openedAt;

  final double position;
  final double progress;
  final bool owned;
  final bool pinned;
  final bool fresh;

  RecentEntry copyWith({
    int? openedAt,
    double? position,
    double? progress,
    int? size,
    String? path,
    bool? pinned,
    bool? fresh,
  }) {
    return RecentEntry(
      id: id,
      name: name,
      path: path ?? this.path,
      kind: kind,
      size: size ?? this.size,
      openedAt: openedAt ?? this.openedAt,
      position: position ?? this.position,
      progress: progress ?? this.progress,
      owned: owned,
      pinned: pinned ?? this.pinned,
      fresh: fresh ?? this.fresh,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'path': path,
    'kind': kind.name,
    'size': size,
    'openedAt': openedAt,
    'pos': position,
    'progress': progress,
    'owned': owned,
    'pinned': pinned,
    'fresh': fresh,
  };
}

class RecentStore extends ChangeNotifier {
  RecentStore._(this._prefs, this._entries);

  static const int maxEntries = 30;
  static const String _key = 'recentDocuments';

  final KvStore _prefs;
  List<RecentEntry> _entries;

  List<RecentEntry> get entries =>
      List<RecentEntry>.unmodifiable(_entries.where((e) => !e.fresh));

  List<RecentEntry> get all => List<RecentEntry>.unmodifiable(_entries);

  static RecentStore load(KvStore prefs) {
    final entries = <RecentEntry>[];
    for (final text in prefs.getStringList(_key) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, Object?>) {
          final entry = RecentEntry.fromJson(decoded);
          if (File(entry.path).existsSync()) entries.add(entry);
        }
      } on Object {
        continue;
      }
    }
    return RecentStore._(prefs, entries);
  }

  void _save() {
    _prefs.setStringList(_key, <String>[
      for (final e in _entries) jsonEncode(e.toJson()),
    ]);
    notifyListeners();
  }

  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    return cleaned.isEmpty ? 'document' : cleaned;
  }

  Future<RecentEntry> add({
    required String sourcePath,
    required String name,
    required DocumentKind kind,
    bool removeSource = true,
    bool fresh = false,
  }) async {
    final source = File(sourcePath);
    final size = await source.length();
    final safe = _safeName(name);

    RecentEntry? existing;
    for (final e in _entries) {
      if (!removeSource
          ? e.path == sourcePath
          : (e.name == safe && e.size == size)) {
        existing = e;
        break;
      }
    }
    final id =
        existing?.id ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final String target;
    if (removeSource) {
      final folder = Directory('${await AppDirs.data()}/recent/$id');
      await folder.create(recursive: true);
      target = '${folder.path}/$safe';
      try {
        await source.rename(target);
      } on FileSystemException {
        await source.copy(target);
        await safely(source.delete);
      }
    } else {
      target = sourcePath;
    }

    final entry = RecentEntry(
      id: id,
      name: safe,
      path: target,
      kind: kind,
      size: size,
      openedAt: DateTime.now().millisecondsSinceEpoch,
      position: existing?.position ?? 0,
      progress: existing?.progress ?? 0,
      owned: removeSource,
      pinned: existing?.pinned ?? false,
      fresh: fresh,
    );
    _entries
      ..removeWhere((e) => e.id == id)
      ..insert(0, entry);
    while (_entries.length > maxEntries) {
      var drop = _entries.lastIndexWhere((e) => !e.pinned);
      if (drop < 0) drop = _entries.length - 1;
      final old = _entries.removeAt(drop);
      await _deleteFiles(old);
    }
    _save();
    return entry;
  }

  RecentEntry? byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  void saveProgress(String id, double position, double progress) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(
      position: position,
      progress: progress < 0 ? 0.0 : (progress > 1 ? 1.0 : progress),
    );
    _prefs.setStringList(_key, <String>[
      for (final e in _entries) jsonEncode(e.toJson()),
    ]);
    scheduleMicrotask(notifyListeners);
  }

  void updateSize(String id, int size) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(size: size);
    _save();
  }

  void settle(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0 || !_entries[index].fresh) return;
    final entry = _entries
        .removeAt(index)
        .copyWith(
          fresh: false,
          openedAt: DateTime.now().millisecondsSinceEpoch,
        );
    _entries.insert(0, entry);
    _save();
  }

  Future<void> prune(Set<String> pending) async {
    final stale = <RecentEntry>[
      for (final e in _entries)
        if (e.fresh && !pending.contains(e.id)) e,
    ];
    if (stale.isEmpty) return;
    _entries.removeWhere(stale.contains);
    _save();
    for (final e in stale) {
      await _deleteFiles(e);
    }
  }

  void togglePin(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(pinned: !_entries[index].pinned);
    _save();
  }

  void touch(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final entry = _entries
        .removeAt(index)
        .copyWith(openedAt: DateTime.now().millisecondsSinceEpoch);
    _entries.insert(0, entry);
    _save();
  }

  Future<void> remove(String id) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final entry = _entries.removeAt(index);
    _save();
    await _deleteFiles(entry);
  }

  Future<void> clear() async {
    final old = List<RecentEntry>.of(_entries);
    _entries = <RecentEntry>[];
    _save();
    for (final e in old) {
      await _deleteFiles(e);
    }
  }

  Future<void> _deleteFiles(RecentEntry entry) async {
    await EditHistory.delete(entry.id);
    if (!entry.owned) return;
    try {
      await File(entry.path).parent.delete(recursive: true);
    } on Object {
      return;
    }
  }
}
