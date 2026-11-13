import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:olako/core/app_dirs.dart';
import 'package:olako/localization/localization.dart';

class FontEntry {
  const FontEntry(this.family, this.group);

  final String family;
  final String group;

  String get key => family.replaceAll(' ', '_');
}

abstract class FontLibrary {
  static const String sansGroup = 'Sans-serif';
  static const String serifGroup = 'Serif';
  static const String monoGroup = 'Monospace';
  static const String arabicGroup = 'Persian and Arabic';

  static const List<FontEntry> catalog = <FontEntry>[
    FontEntry('Vazirmatn', arabicGroup),
    FontEntry('Noto Naskh Arabic', arabicGroup),
    FontEntry('Noto Sans Arabic', arabicGroup),
    FontEntry('Noto Kufi Arabic', arabicGroup),
    FontEntry('Noto Nastaliq Urdu', arabicGroup),
    FontEntry('Amiri', arabicGroup),
    FontEntry('Scheherazade New', arabicGroup),
    FontEntry('Lateef', arabicGroup),
    FontEntry('Harmattan', arabicGroup),
    FontEntry('Markazi Text', arabicGroup),
    FontEntry('Cairo', arabicGroup),
    FontEntry('Tajawal', arabicGroup),
    FontEntry('Almarai', arabicGroup),
    FontEntry('Changa', arabicGroup),
    FontEntry('El Messiri', arabicGroup),
    FontEntry('Reem Kufi', arabicGroup),
    FontEntry('Readex Pro', arabicGroup),
    FontEntry('Alexandria', arabicGroup),
    FontEntry('IBM Plex Sans Arabic', arabicGroup),
    FontEntry('Roboto', sansGroup),
    FontEntry('Open Sans', sansGroup),
    FontEntry('Noto Sans', sansGroup),
    FontEntry('Inter', sansGroup),
    FontEntry('Lato', sansGroup),
    FontEntry('Source Sans 3', sansGroup),
    FontEntry('Montserrat', sansGroup),
    FontEntry('Poppins', sansGroup),
    FontEntry('Nunito', sansGroup),
    FontEntry('Merriweather', serifGroup),
    FontEntry('Lora', serifGroup),
    FontEntry('Noto Serif', serifGroup),
    FontEntry('Source Serif 4', serifGroup),
    FontEntry('PT Serif', serifGroup),
    FontEntry('EB Garamond', serifGroup),
    FontEntry('Crimson Pro', serifGroup),
    FontEntry('Playfair Display', serifGroup),
    FontEntry('Fira Code', monoGroup),
    FontEntry('JetBrains Mono', monoGroup),
    FontEntry('Source Code Pro', monoGroup),
    FontEntry('Roboto Mono', monoGroup),
    FontEntry('IBM Plex Mono', monoGroup),
  ];

  static const Map<String, String> _variants = <String, String>{
    'regular': '400',
    'bold': '700',
    'italic': '400italic',
    'bolditalic': '700italic',
  };

  static Future<Directory> _root() async {
    final root = Directory('${await AppDirs.data()}/fonts');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static Future<String> specFor(String key) async {
    final root = await _root();
    return 'dir:${root.path}/$key';
  }

  static Future<Set<String>> installed() async {
    final out = <String>{};
    try {
      final root = await _root();
      await for (final item in root.list()) {
        if (item is! Directory) continue;
        final name = item.path.split('/').last;
        if (name.endsWith('.part')) continue;
        if (await File('${item.path}/regular.ttf').exists() ||
            await File('${item.path}/regular.otf').exists() ||
            await File('${item.path}/regular.ttc').exists()) {
          out.add(name);
        }
      }
    } on Object {
      return out;
    }
    return out;
  }

  static Future<void> remove(String key) async {
    try {
      final root = await _root();
      final folder = Directory('${root.path}/$key');
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object {
      return;
    }
  }

  static Future<String?> importFile(String path) async {
    final lower = path.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final extension = dot < 0 ? '' : lower.substring(dot + 1);
    if (extension != 'ttf' && extension != 'otf' && extension != 'ttc')
      return null;
    try {
      final root = await _root();
      var base = path.split('/').last;
      base = base.substring(0, base.length - extension.length - 1);
      base = base.replaceAll(RegExp(r'[^A-Za-z0-9._\-\u0080-￿]'), '_');
      if (base.isEmpty) base = 'font';
      final folder = Directory('${root.path}/$base');
      if (await folder.exists()) await folder.delete(recursive: true);
      await folder.create(recursive: true);
      await File(path).copy('${folder.path}/regular.$extension');
      return base;
    } on Object {
      return null;
    }
  }

  static Future<Uint8List> _bytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<Uint8List?> _get(HttpClient client, Uri uri) async {
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, 'olako');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      return await _bytes(response).timeout(const Duration(seconds: 90));
    } on Object {
      return null;
    }
  }

  static Future<bool> download(
    FontEntry entry,
    void Function(double progress) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final root = await _root();
      final temp = Directory('${root.path}/${entry.key}.part');
      if (await temp.exists()) await temp.delete(recursive: true);
      await temp.create(recursive: true);
      final seen = <String>{};
      var done = 0;
      var regularSaved = false;
      for (final variant in _variants.entries) {
        final css = await _get(
          client,
          Uri.parse(
            'https://fonts.googleapis.com/css?family=${entry.family.replaceAll(' ', '+')}:${variant.value}',
          ),
        );
        done++;
        onProgress(done / (_variants.length * 2));
        if (css == null) {
          if (variant.key == 'regular') break;
          continue;
        }
        final match = RegExp(
          r'url\((https://[^)]+)\)',
        ).firstMatch(utf8.decode(css, allowMalformed: true));
        final link = match?.group(1);
        if (link == null || !seen.add(link)) continue;
        final data = await _get(client, Uri.parse(link));
        onProgress((done + 1) / (_variants.length * 2));
        if (data == null || data.isEmpty) {
          if (variant.key == 'regular') break;
          continue;
        }
        final extension = link.toLowerCase().contains('.otf') ? 'otf' : 'ttf';
        await File(
          '${temp.path}/${variant.key}.$extension',
        ).writeAsBytes(data, flush: true);
        if (variant.key == 'regular') regularSaved = true;
      }
      if (!regularSaved) {
        await temp.delete(recursive: true);
        return false;
      }
      final target = Directory('${root.path}/${entry.key}');
      if (await target.exists()) await target.delete(recursive: true);
      await temp.rename(target.path);
      return true;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static String nameOf(String spec) {
    switch (spec) {
      case 'sans':
        return 'Sans-serif'.tr;
      case 'serif':
        return 'Serif'.tr;
      case 'mono':
        return 'Monospace'.tr;
      case 'same':
        return 'Same as text'.tr;
    }
    if (spec.startsWith('dir:')) {
      return spec.split('/').last.replaceAll('_', ' ');
    }
    return spec;
  }
}
