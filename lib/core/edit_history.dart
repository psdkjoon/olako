import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:olako/core/app_dirs.dart';

class EditSnapshot {
  const EditSnapshot(this.text, this.cursor);

  final String text;
  final int cursor;
}

class EditHistory {
  EditHistory(this.id);

  static const int maxItems = 200;
  static const int maxChars = 4000000;

  static final ValueNotifier<Set<String>> pending = ValueNotifier<Set<String>>(
    <String>{},
  );

  static Future<void> scan() async {
    try {
      final folder = Directory('${await AppDirs.data()}/edits');
      if (!await folder.exists()) return;
      final ids = <String>{};
      await for (final item in folder.list()) {
        final name = item.path.split('/').last;
        if (name.endsWith('.draft'))
          ids.add(name.substring(0, name.length - 6));
      }
      pending.value = ids;
    } on Object {
      return;
    }
  }

  static void _mark(String id, bool on) {
    final next = Set<String>.of(pending.value);
    final changed = on ? next.add(id) : next.remove(id);
    if (changed) pending.value = next;
  }

  final String id;
  final List<EditSnapshot> _items = <EditSnapshot>[];
  int _index = -1;

  bool get canUndo => _index > 0;
  bool get canRedo => _index >= 0 && _index < _items.length - 1;
  EditSnapshot? get current => _index < 0 ? null : _items[_index];

  static Future<File> _file(String id) async {
    final folder = Directory('${await AppDirs.data()}/edits');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/$id.json');
  }

  static Future<File> _draft(String id) async {
    final folder = Directory('${await AppDirs.data()}/edits');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/$id.draft');
  }

  static Future<String?> readDraft(String id) async {
    try {
      final file = await _draft(id);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on Object {
      return null;
    }
  }

  static Future<void> writeDraft(String id, String text) async {
    try {
      final file = await _draft(id);
      await file.writeAsString(text, flush: true);
      _mark(id, true);
    } on Object {
      return;
    }
  }

  static Future<void> deleteDraft(String id) async {
    try {
      final file = await _draft(id);
      if (await file.exists()) await file.delete();
      _mark(id, false);
    } on Object {
      return;
    }
  }

  static Future<void> delete(String id) async {
    await deleteDraft(id);
    try {
      final file = await _file(id);
      if (await file.exists()) await file.delete();
    } on Object {
      return;
    }
  }

  Future<void> load(String currentText) async {
    _items.clear();
    _index = -1;
    try {
      final file = await _file(id);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final rows = decoded['s'];
          final at = decoded['i'];
          if (rows is List && at is int) {
            for (final row in rows) {
              if (row is List &&
                  row.length == 2 &&
                  row[0] is String &&
                  row[1] is int) {
                _items.add(EditSnapshot(row[0] as String, row[1] as int));
              }
            }
            _index = at;
          }
        }
      }
    } on Object {
      _items.clear();
      _index = -1;
    }
    final valid = _index >= 0 && _index < _items.length;
    if (!valid || _items[_index].text != currentText) {
      _items
        ..clear()
        ..add(EditSnapshot(currentText, currentText.length));
      _index = 0;
    }
  }

  Future<void> save() async {
    try {
      final file = await _file(id);
      await file.writeAsString(
        jsonEncode(<String, Object>{
          'i': _index,
          's': <List<Object>>[
            for (final item in _items) <Object>[item.text, item.cursor],
          ],
        }),
      );
    } on Object {
      return;
    }
  }

  void record(String text, int cursor) {
    if (_index >= 0 && _items[_index].text == text) return;
    if (_index < _items.length - 1) {
      _items.removeRange(_index + 1, _items.length);
    }
    _items.add(EditSnapshot(text, cursor));
    _index = _items.length - 1;
    _trim();
  }

  void _trim() {
    var total = 0;
    for (final item in _items) {
      total += item.text.length;
    }
    while (_items.length > 1 &&
        (_items.length > maxItems || total > maxChars)) {
      total -= _items.first.text.length;
      _items.removeAt(0);
      _index--;
    }
  }

  EditSnapshot? undo() {
    if (!canUndo) return null;
    _index--;
    return _items[_index];
  }

  EditSnapshot? redo() {
    if (!canRedo) return null;
    _index++;
    return _items[_index];
  }
}
