import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/docx_reader.dart';
import 'package:olako/reader/markdown_reader.dart';
import 'package:olako/reader/odt_reader.dart';
import 'package:olako/reader/pdf_reader.dart';
import 'package:olako/reader/plain_reader.dart';
import 'package:olako/reader/plain_rescue.dart';
import 'package:olako/reader/pptx_reader.dart';
import 'package:olako/reader/xlsx_reader.dart';
import 'package:olako/reader/zip_archive.dart';

enum DocumentKind { word, slides, markdown, pdf, text, table, sheet, opendoc }

DocumentKind? detectKind(String name, [String mime = '']) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  switch (extension) {
    case 'docx':
      return DocumentKind.word;
    case 'pptx':
      return DocumentKind.slides;
    case 'md':
    case 'markdown':
    case 'mdown':
    case 'mkd':
    case 'mkdn':
      return DocumentKind.markdown;
    case 'pdf':
      return DocumentKind.pdf;
    case 'txt':
    case 'text':
    case 'log':
      return DocumentKind.text;
    case 'csv':
    case 'tsv':
      return DocumentKind.table;
    case 'xlsx':
      return DocumentKind.sheet;
    case 'odt':
      return DocumentKind.opendoc;
  }
  final type = mime.toLowerCase();
  if (type.contains('wordprocessingml')) return DocumentKind.word;
  if (type.contains('presentationml')) return DocumentKind.slides;
  if (type.contains('markdown')) return DocumentKind.markdown;
  if (type.contains('pdf')) return DocumentKind.pdf;
  if (type.contains('spreadsheetml')) return DocumentKind.sheet;
  if (type.contains('opendocument.text')) return DocumentKind.opendoc;
  if (type.contains('csv') || type.contains('tab-separated')) {
    return DocumentKind.table;
  }
  if (type == 'text/plain') return DocumentKind.text;
  return null;
}

const int _maxFileBytes = 120 * 1024 * 1024;

Future<DocumentKind?> sniffKind(String path) async {
  try {
    return await Isolate.run(() => _sniff(path));
  } on Object {
    return null;
  }
}

DocumentKind? _sniff(String path) {
  final file = File(path);
  final length = file.lengthSync();
  if (length == 0 || length > _maxFileBytes) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.length >= 5 &&
      bytes[0] == 0x25 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x46) {
    return DocumentKind.pdf;
  }
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    try {
      final zip = ZipArchive.parse(bytes);
      if (zip.contains('word/document.xml')) return DocumentKind.word;
      if (zip.contains('ppt/presentation.xml')) return DocumentKind.slides;
      if (zip.contains('xl/workbook.xml')) return DocumentKind.sheet;
      if (zip.contains('content.xml') && zip.contains('mimetype')) {
        return DocumentKind.opendoc;
      }
    } on Object {
      return null;
    }
    return null;
  }
  final sample = bytes.length > 4096 ? 4096 : bytes.length;
  for (var i = 0; i < sample; i++) {
    final b = bytes[i];
    if (b == 0 || (b < 9) || (b > 13 && b < 32)) return null;
  }
  return DocumentKind.text;
}

Future<LoadOutcome> loadDocument(String path, DocumentKind kind) async {
  try {
    return await Isolate.run(() => _load(path, kind));
  } on Object catch (e) {
    return LoadOutcome.failed(DocumentProblem.damaged, '$e');
  }
}

LoadOutcome _load(String path, DocumentKind kind) {
  try {
    final file = File(path);
    if (file.lengthSync() > _maxFileBytes) {
      return const LoadOutcome.failed(DocumentProblem.tooLarge);
    }
    final bytes = file.readAsBytesSync();
    switch (kind) {
      case DocumentKind.markdown:
        return LoadOutcome.ready(
          readMarkdown(utf8.decode(bytes, allowMalformed: true)),
        );
      case DocumentKind.text:
        return LoadOutcome.ready(
          readPlainText(utf8.decode(bytes, allowMalformed: true)),
        );
      case DocumentKind.table:
        return LoadOutcome.ready(
          readDelimited(utf8.decode(bytes, allowMalformed: true)),
        );
      case DocumentKind.pdf:
        return LoadOutcome.ready(readPdf(bytes));
      case DocumentKind.word:
      case DocumentKind.slides:
      case DocumentKind.sheet:
      case DocumentKind.opendoc:
        break;
    }
    if (_isOleFile(bytes)) {
      return const LoadOutcome.failed(DocumentProblem.legacyFormat);
    }
    final zip = ZipArchive.parse(bytes);
    LoadedDocument? document;
    var failure = '';
    try {
      document = switch (kind) {
        DocumentKind.word => readDocx(zip),
        DocumentKind.slides => readPptx(zip),
        DocumentKind.sheet => readXlsx(zip),
        DocumentKind.opendoc => readOdt(zip),
        _ => null,
      };
    } on DocumentFormatException catch (e) {
      if (e.message.contains('password')) rethrow;
      failure = e.message;
    } on Object catch (e, trace) {
      failure = '$e\n${_head(trace)}';
    }
    final read = document;
    if (read is TextDocument && read.blocks.isEmpty) {
      document = null;
      failure = failure.isEmpty ? 'The reader found no content.' : failure;
    } else if (read is SlideDeck &&
        read.slides.every((s) => s.shapes.isEmpty)) {
      document = null;
      failure = failure.isEmpty ? 'The reader found no shapes.' : failure;
    }
    if (document != null) return LoadOutcome.ready(document);
    LoadedDocument? rescued;
    try {
      rescued = switch (kind) {
        DocumentKind.word => rescueDocx(zip),
        DocumentKind.slides => rescuePptx(zip),
        _ => null,
      };
    } on DocumentFormatException catch (e) {
      if (e.message.contains('password')) rethrow;
    } on Object {
      rescued = null;
    }
    if (rescued == null)
      return LoadOutcome.failed(DocumentProblem.damaged, failure);
    return LoadOutcome.ready(rescued, failure.isEmpty ? 'rescued' : failure);
  } on DocumentFormatException catch (e) {
    final locked = e.message.contains('password');
    final empty = e.message.contains('no readable text');
    return LoadOutcome.failed(
      locked
          ? DocumentProblem.encrypted
          : (empty ? DocumentProblem.noText : DocumentProblem.damaged),
      e.message,
    );
  } on Object catch (e, trace) {
    return LoadOutcome.failed(DocumentProblem.damaged, '$e\n${_head(trace)}');
  }
}

String _head(StackTrace trace) {
  final lines = trace.toString().split('\n');
  return lines.take(5).join('\n');
}

bool _isOleFile(Uint8List bytes) {
  const signature = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}
