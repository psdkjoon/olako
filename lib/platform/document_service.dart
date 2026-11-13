import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

class PdfBitmap {
  const PdfBitmap(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

class PdfInfo {
  const PdfInfo({required this.id, required this.pages, this.error = ''});

  const PdfInfo.failed(this.error) : id = 0, pages = const <Size>[];

  final int id;
  final List<Size> pages;
  final String error;
}

class PdfExportResult {
  const PdfExportResult({this.path = '', this.pages = 0, this.error = ''});

  final String path;
  final int pages;
  final String error;

  bool get ok => error.isEmpty && path.isNotEmpty;
}

class PdfEditResult {
  const PdfEditResult({
    this.path = '',
    this.name = '',
    this.pages = 0,
    this.error = '',
  });

  final String path;
  final String name;
  final int pages;
  final String error;

  bool get ok => error.isEmpty && path.isNotEmpty;
}

class LibraryFile {
  const LibraryFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final int size;
  final int modified;
}

abstract class DocumentService {
  static const _channel = MethodChannel('olako/documents');

  static String? _text(Object? value) => value is String ? value : null;

  static Future<String?> copy(String uri) async {
    try {
      return await _channel.invokeMethod<String>('copy', <String, Object?>{
        'uri': uri,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> pick() async {
    try {
      return await _channel.invokeMethod<String>('pick');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<List<String>> pickMany(List<String> types) async {
    try {
      final raw = await _channel.invokeListMethod<String>(
        'pick',
        <String, Object?>{'types': types, 'multiple': true},
      );
      return raw ?? const <String>[];
    } on PlatformException {
      return const <String>[];
    } on MissingPluginException {
      return const <String>[];
    }
  }

  static Future<List<PdfEditResult>> editPdf(
    List<Map<String, Object?>> jobs,
  ) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'editPdf',
        <String, Object?>{'jobs': jobs},
      );
      final out = <PdfEditResult>[];
      for (final item in raw ?? const <Object?>[]) {
        if (item is! Map) {
          out.add(const PdfEditResult(error: 'bad answer'));
          continue;
        }
        final error = item['error'];
        if (error is String) {
          out.add(PdfEditResult(error: error));
          continue;
        }
        final path = item['path'];
        final name = item['name'];
        final pages = item['pages'];
        out.add(
          PdfEditResult(
            path: path is String ? path : '',
            name: name is String ? name : '',
            pages: pages is num ? pages.toInt() : 0,
          ),
        );
      }
      if (out.isEmpty) out.add(const PdfEditResult(error: 'no answer'));
      return out;
    } on PlatformException catch (e) {
      return <PdfEditResult>[
        PdfEditResult(error: '${e.code} ${e.message ?? ''}'),
      ];
    } on MissingPluginException {
      return const <PdfEditResult>[PdfEditResult(error: 'no native writer')];
    }
  }

  static Future<bool> shareMany(List<String> paths, String mime) async {
    try {
      final done = await _channel.invokeMethod<bool>(
        'shareMany',
        <String, Object?>{'paths': paths, 'mime': mime},
      );
      return done ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> share(String path, String mime) async {
    try {
      final done = await _channel.invokeMethod<bool>('share', <String, Object?>{
        'path': path,
        'mime': mime,
      });
      return done ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<PdfExportResult> exportPdf(Map<String, Object?> args) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'exportPdf',
        args,
      );
      if (raw == null) return const PdfExportResult(error: 'no answer');
      final error = raw['error'];
      if (error is String) return PdfExportResult(error: error);
      final path = raw['path'];
      final pages = raw['pages'];
      if (path is! String) return const PdfExportResult(error: 'bad answer');
      return PdfExportResult(
        path: path,
        pages: pages is num ? pages.toInt() : 0,
      );
    } on PlatformException catch (e) {
      return PdfExportResult(error: '${e.code} ${e.message ?? ''}');
    } on MissingPluginException {
      return const PdfExportResult(error: 'no native writer');
    }
  }

  static Future<bool> saveDownload(String path, String name) async {
    try {
      final done = await _channel.invokeMethod<bool>(
        'saveDownload',
        <String, Object?>{'path': path, 'name': name},
      );
      return done ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> storageGranted() async {
    try {
      return await _channel.invokeMethod<bool>('storageGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> requestStorage() async {
    try {
      return await _channel.invokeMethod<bool>('requestStorage') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<LibraryFile>> scan() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('scan');
      final out = <LibraryFile>[];
      for (final item in raw ?? const <Object?>[]) {
        if (item is! Map) continue;
        final path = _text(item['path']);
        final name = _text(item['name']);
        if (path == null || name == null) continue;
        final size = item['size'];
        final modified = item['modified'];
        out.add(
          LibraryFile(
            path: path,
            name: name,
            size: size is num ? size.toInt() : 0,
            modified: modified is num ? modified.toInt() : 0,
          ),
        );
      }
      return out;
    } on PlatformException {
      return const <LibraryFile>[];
    } on MissingPluginException {
      return const <LibraryFile>[];
    }
  }

  static Future<PdfInfo> pdfOpen(String path) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'pdfOpen',
        <String, Object?>{'path': path},
      );
      if (raw == null) return const PdfInfo.failed('no answer');
      final error = raw['error'];
      if (error is String) return PdfInfo.failed(error);
      final id = raw['id'];
      final sizes = raw['sizes'];
      if (id is! int || sizes is! List)
        return const PdfInfo.failed('bad answer');
      final pages = <Size>[];
      for (var i = 0; i + 1 < sizes.length; i += 2) {
        final width = sizes[i];
        final height = sizes[i + 1];
        if (width is num && height is num && width > 0 && height > 0) {
          pages.add(Size(width.toDouble(), height.toDouble()));
        } else {
          pages.add(const Size(595, 842));
        }
      }
      return PdfInfo(id: id, pages: pages);
    } on PlatformException catch (e) {
      return PdfInfo.failed('${e.code} ${e.message ?? ''}');
    } on MissingPluginException {
      return const PdfInfo.failed('no native renderer');
    }
  }

  static Future<PdfBitmap?> pdfRender(int id, int page, int width) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'pdfRender',
        <String, Object?>{'id': id, 'page': page, 'width': width},
      );
      if (bytes == null || bytes.length < 8) return null;
      final header = ByteData.sublistView(bytes, 0, 8);
      final w = header.getInt32(0, Endian.little);
      final h = header.getInt32(4, Endian.little);
      if (w <= 0 || h <= 0 || bytes.length < 8 + w * h * 4) return null;
      return PdfBitmap(w, h, Uint8List.sublistView(bytes, 8));
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> pdfClose(int id) async {
    try {
      await _channel.invokeMethod<void>('pdfClose', <String, Object?>{
        'id': id,
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
