import 'dart:io';
import 'dart:isolate';

import 'package:olako/reader/pdf_reader.dart';

class _Job {
  const _Job(this.port, this.path, this.first);

  final SendPort port;
  final String path;
  final int first;
}

void _entry(_Job job) {
  try {
    final file = File(job.path);
    if (file.lengthSync() <= 120 * 1024 * 1024) {
      extractPdfLayer(file.readAsBytesSync(), job.first, job.port.send);
    }
  } on Object {
    job.port.send(null);
  }
  job.port.send(null);
}

class PdfLayerLoader {
  PdfLayerLoader(this.path, this.first, this.onPage);

  final String path;
  final int first;
  final void Function(PdfLayerPage page) onPage;

  Isolate? _isolate;
  ReceivePort? _port;
  bool _closed = false;

  Future<void> start() async {
    final port = ReceivePort();
    _port = port;
    port.listen((Object? message) {
      if (_closed) return;
      if (message is PdfLayerPage) {
        onPage(message);
      } else {
        close();
      }
    });
    try {
      _isolate = await Isolate.spawn<_Job>(
        _entry,
        _Job(port.sendPort, path, first),
      );
      if (_closed) _isolate?.kill(priority: Isolate.immediate);
    } on Object {
      close();
    }
  }

  void close() {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
  }
}
