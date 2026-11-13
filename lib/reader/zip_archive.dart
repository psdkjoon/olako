import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DocumentFormatException implements Exception {
  const DocumentFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ZipEntry {
  const _ZipEntry({
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.headerOffset,
    required this.encrypted,
  });

  final int method;
  final int compressedSize;
  final int size;
  final int headerOffset;
  final bool encrypted;
}

class ZipArchive {
  ZipArchive._(this._bytes, this._entries, this._lowerNames);

  static const int maxEntryBytes = 256 * 1024 * 1024;

  static const int _eocdSignature = 0x06054b50;
  static const int _centralSignature = 0x02014b50;
  static const int _localSignature = 0x04034b50;

  final Uint8List _bytes;
  final Map<String, _ZipEntry> _entries;
  final Map<String, String> _lowerNames;

  static ZipArchive parse(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const DocumentFormatException('Not a ZIP file.');
    }
    final data = ByteData.sublistView(bytes);
    var eocd = -1;
    final lowest = bytes.length > 22 + 65535 ? bytes.length - 22 - 65535 : 0;
    for (var i = bytes.length - 22; i >= lowest; i--) {
      if (data.getUint32(i, Endian.little) == _eocdSignature) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw const DocumentFormatException('Not a ZIP file.');
    }
    final count = data.getUint16(eocd + 10, Endian.little);
    final directorySize = data.getUint32(eocd + 12, Endian.little);
    final directoryOffset = data.getUint32(eocd + 16, Endian.little);
    if (directoryOffset == 0xFFFFFFFF ||
        directorySize == 0xFFFFFFFF ||
        directoryOffset + directorySize > bytes.length) {
      throw const DocumentFormatException('Unsupported or damaged ZIP file.');
    }

    final entries = <String, _ZipEntry>{};
    final lowerNames = <String, String>{};
    var p = directoryOffset;
    for (var n = 0; n < count; n++) {
      if (p + 46 > bytes.length ||
          data.getUint32(p, Endian.little) != _centralSignature) {
        break;
      }
      final flags = data.getUint16(p + 8, Endian.little);
      final method = data.getUint16(p + 10, Endian.little);
      final compressedSize = data.getUint32(p + 20, Endian.little);
      final size = data.getUint32(p + 24, Endian.little);
      final nameLength = data.getUint16(p + 28, Endian.little);
      final extraLength = data.getUint16(p + 30, Endian.little);
      final commentLength = data.getUint16(p + 32, Endian.little);
      final headerOffset = data.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLength > bytes.length) break;
      final name = utf8.decode(
        Uint8List.sublistView(bytes, p + 46, p + 46 + nameLength),
        allowMalformed: true,
      );
      entries[name] = _ZipEntry(
        method: method,
        compressedSize: compressedSize,
        size: size,
        headerOffset: headerOffset,
        encrypted: flags & 1 != 0,
      );
      lowerNames[name.toLowerCase()] = name;
      p += 46 + nameLength + extraLength + commentLength;
    }
    if (entries.isEmpty) {
      throw const DocumentFormatException('The ZIP file is empty.');
    }
    return ZipArchive._(bytes, entries, lowerNames);
  }

  Iterable<String> get names => _entries.keys;

  String? _resolve(String name) {
    if (_entries.containsKey(name)) return name;
    return _lowerNames[name.toLowerCase()];
  }

  bool contains(String name) => _resolve(name) != null;

  Uint8List? read(String name) {
    final key = _resolve(name);
    if (key == null) return null;
    final entry = _entries[key]!;
    if (entry.encrypted) {
      throw const DocumentFormatException(
        'The document is password protected.',
      );
    }
    if (entry.size > maxEntryBytes) {
      throw const DocumentFormatException(
        'A part of the document is too large.',
      );
    }
    final data = ByteData.sublistView(_bytes);
    final header = entry.headerOffset;
    if (header + 30 > _bytes.length ||
        data.getUint32(header, Endian.little) != _localSignature) {
      throw const DocumentFormatException('Damaged ZIP file.');
    }
    final nameLength = data.getUint16(header + 26, Endian.little);
    final extraLength = data.getUint16(header + 28, Endian.little);
    final start = header + 30 + nameLength + extraLength;
    final end = start + entry.compressedSize;
    if (end > _bytes.length) {
      throw const DocumentFormatException('Damaged ZIP file.');
    }
    final raw = Uint8List.sublistView(_bytes, start, end);
    if (entry.method == 0) return raw;
    if (entry.method != 8) {
      throw const DocumentFormatException('Unsupported compression.');
    }
    final List<int> inflated;
    try {
      inflated = ZLibDecoder(raw: true).convert(raw);
    } on Object {
      throw const DocumentFormatException('Damaged ZIP file.');
    }
    return inflated is Uint8List ? inflated : Uint8List.fromList(inflated);
  }

  String? readString(String name) {
    final bytes = read(name);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}
