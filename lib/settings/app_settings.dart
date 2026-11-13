import 'package:flutter/material.dart';
import 'package:olako/core/kv_store.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/theme/catppuccin.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs) {
    _themeMode = _byName(
      ThemeMode.values,
      _prefs.getString('themeMode'),
      _themeMode,
    );
    _language = _prefs.getString('language') ?? L10n.system;
    L10n.code = L10n.resolve(_language);
    _checkUpdates = _prefs.getBool('checkUpdates') ?? _checkUpdates;
    final accent = _prefs.getString('accent');
    if (accent != null && CatppuccinPalette.accents.contains(accent)) {
      _accent = accent;
    }
    _appearanceUpdatedAt =
        _prefs.getInt('accentUpdatedAt') ?? _appearanceUpdatedAt;
    _syncAppearance = _prefs.getBool('syncAccent') ?? _syncAppearance;
    final scale = _prefs.getInt('readerScale');
    if (scale != null && scale >= minReaderScale && scale <= maxReaderScale) {
      _readerScale = scale;
    }
    _slidesAsText = _prefs.getBool('slidesAsText') ?? _slidesAsText;
    _keepAwake = _prefs.getBool('keepAwake') ?? _keepAwake;
    _invertPages = _prefs.getBool('invertPages') ?? _invertPages;
    _pdfOptions = _prefs.getString('pdfOptions') ?? _pdfOptions;
    _pdfStyles = _prefs.getString('pdfStyles') ?? _pdfStyles;
  }

  static const int minReaderScale = 80;
  static const int maxReaderScale = 200;

  static AppSettings load(KvStore store) => AppSettings._(store);

  static T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  final KvStore _prefs;

  ThemeMode _themeMode = ThemeMode.system;
  String _language = L10n.system;
  bool _checkUpdates = true;
  String _accent = CatppuccinPalette.defaultAccent;
  int _appearanceUpdatedAt = 0;
  bool _syncAppearance = true;
  int _readerScale = 100;
  bool _slidesAsText = false;
  bool _keepAwake = true;
  bool _invertPages = false;
  String _pdfOptions = '';
  String _pdfStyles = '';

  ThemeMode get themeMode => _themeMode;
  String get language => _language;
  bool get checkUpdates => _checkUpdates;
  String get accent => _accent;

  int get appearanceUpdatedAt => _appearanceUpdatedAt;
  bool get syncAppearance => _syncAppearance;

  int get readerScale => _readerScale;

  bool get slidesAsText => _slidesAsText;
  bool get keepAwake => _keepAwake;
  bool get invertPages => _invertPages;
  String get pdfOptions => _pdfOptions;
  String get pdfStyles => _pdfStyles;

  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _stamp();
    _set(() => _themeMode = value, 'themeMode', value.name);
  }

  set language(String value) {
    _language = value;
    L10n.code = L10n.resolve(value);
    _prefs.setString('language', value);
    notifyListeners();
  }

  set checkUpdates(bool value) =>
      _set(() => _checkUpdates = value, 'checkUpdates', value);

  set accent(String value) {
    if (value == _accent && _appearanceUpdatedAt != 0) return;
    _stamp();
    _set(() => _accent = value, 'accent', value);
  }

  set syncAppearance(bool value) =>
      _set(() => _syncAppearance = value, 'syncAccent', value);

  set readerScale(int value) {
    final clamped = value < minReaderScale
        ? minReaderScale
        : (value > maxReaderScale ? maxReaderScale : value);
    if (clamped == _readerScale) return;
    _set(() => _readerScale = clamped, 'readerScale', clamped);
  }

  set slidesAsText(bool value) =>
      _set(() => _slidesAsText = value, 'slidesAsText', value);

  set keepAwake(bool value) =>
      _set(() => _keepAwake = value, 'keepAwake', value);

  set invertPages(bool value) =>
      _set(() => _invertPages = value, 'invertPages', value);

  void storePdfOptions(String value) {
    if (value == _pdfOptions) return;
    _pdfOptions = value;
    _prefs.setString('pdfOptions', value);
  }

  void storePdfStyles(String value) {
    if (value == _pdfStyles) return;
    _pdfStyles = value;
    _prefs.setString('pdfStyles', value);
  }

  void _stamp() {
    _appearanceUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    _prefs.setInt('accentUpdatedAt', _appearanceUpdatedAt);
  }

  void adoptAppearance(String accent, String? mode, int updatedAt) {
    if (!CatppuccinPalette.accents.contains(accent)) return;
    if (updatedAt <= _appearanceUpdatedAt) return;
    _accent = accent;
    if (mode != null) _themeMode = _byName(ThemeMode.values, mode, _themeMode);
    _appearanceUpdatedAt = updatedAt;
    _prefs.setString('accent', accent);
    _prefs.setString('themeMode', _themeMode.name);
    _prefs.setInt('accentUpdatedAt', updatedAt);
    notifyListeners();
  }

  Future<void> flush() => _prefs.flush();

  void _set(VoidCallback change, String key, Object value) {
    change();
    switch (value) {
      case final bool v:
        _prefs.setBool(key, v);
      case final int v:
        _prefs.setInt(key, v);
      case final String v:
        _prefs.setString(key, v);
    }
    notifyListeners();
  }
}
