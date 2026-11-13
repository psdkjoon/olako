import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:olako/pdf_edit/models.dart';
import 'package:olako/platform/document_service.dart';

class PageImages {
  PageImages();

  static const int _keep = 64;

  final Map<String, ui.Image> _done = <String, ui.Image>{};
  final List<String> _order = <String>[];
  final Map<String, Future<ui.Image?>> _flight = <String, Future<ui.Image?>>{};
  final Map<String, int> _interest = <String, int>{};
  final List<PdfSource> _opened = <PdfSource>[];
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  Future<PdfSource?> load(String path, String name) async {
    final info = await DocumentService.pdfOpen(path);
    if (info.id == 0 || info.pages.isEmpty) return null;
    final source = PdfSource(path: path, name: name, sizes: info.pages);
    source.handle = info.id;
    _opened.add(source);
    return source;
  }

  static String _key(PdfSource source, int page, int width) {
    return '${source.handle}:$page:$width';
  }

  ui.Image? peek(PdfSource source, int page, int width) {
    return _done[_key(source, page, width)];
  }

  Future<ui.Image?> get(PdfSource source, int page, int width) {
    final key = _key(source, page, width);
    _interest[key] = (_interest[key] ?? 0) + 1;
    final hit = _done[key];
    if (hit != null) return Future<ui.Image?>.value(hit);
    final running = _flight[key];
    if (running != null) return running;
    final future = _load(source, page, width, key);
    _flight[key] = future;
    return future;
  }

  void release(PdfSource source, int page, int width) {
    final key = _key(source, page, width);
    final left = (_interest[key] ?? 1) - 1;
    if (left <= 0) {
      _interest.remove(key);
    } else {
      _interest[key] = left;
    }
  }

  Future<ui.Image?> _load(PdfSource source, int page, int width, String key) {
    final completer = Completer<ui.Image?>();
    _tail = _tail.then((_) async {
      ui.Image? image;
      try {
        final wanted = (_interest[key] ?? 0) > 0;
        if (wanted && !_closed && source.handle != 0) {
          image = await _render(source, page, width);
        }
      } on Object {
        image = null;
      }
      unawaited(_flight.remove(key));
      if (image != null) _remember(key, image);
      completer.complete(image);
    });
    return completer.future;
  }

  Future<ui.Image?> _render(PdfSource source, int page, int width) async {
    final bitmap = await DocumentService.pdfRender(source.handle, page, width);
    if (bitmap == null || _closed) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bitmap.pixels,
      bitmap.width,
      bitmap.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _remember(String key, ui.Image image) {
    _done[key] = image;
    _order.remove(key);
    _order.add(key);
    while (_order.length > _keep) {
      final old = _order.removeAt(0);
      _done.remove(old);
    }
  }

  void dispose() {
    _closed = true;
    for (final source in _opened) {
      unawaited(DocumentService.pdfClose(source.handle));
      source.handle = 0;
    }
    _opened.clear();
    _done.clear();
    _order.clear();
  }
}

class PictureStore extends ChangeNotifier {
  final Map<Object, ui.Image> _images = <Object, ui.Image>{};
  final Set<Object> _loading = <Object>{};
  bool _closed = false;

  ui.Image? get(PictureOverlay overlay) {
    final key = overlay.source;
    final hit = _images[key];
    if (hit != null) return hit;
    if (_loading.add(key)) {
      unawaited(_decode(key, overlay.bytes, overlay.path));
    }
    return null;
  }

  Future<void> _decode(Object key, Uint8List? bytes, String path) async {
    try {
      final data = bytes ?? await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      if (_closed) return;
      _images[key] = frame.image;
      notifyListeners();
    } on Object {
      _loading.remove(key);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _images.clear();
    super.dispose();
  }
}

Future<ui.Size?> imageSize(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = ui.Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    buffer.dispose();
    if (size.width <= 0 || size.height <= 0) return null;
    return size;
  } on Object {
    return null;
  }
}
