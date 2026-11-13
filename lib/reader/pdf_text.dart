import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:olako/reader/pdf_objects.dart';
import 'package:olako/reader/pdf_tables.dart';

class PdfShown {
  const PdfShown(this.text, this.width, this.codes, this.spaces);

  final String text;
  final double width;
  final int codes;
  final int spaces;
}

class _CMap {
  const _CMap(this.map, this.codeBytes);

  final Map<int, String> map;
  final int codeBytes;
}

class PdfFont {
  const PdfFont._({
    required this.twoByte,
    required this.directUnicode,
    required this.unicode,
    required this.simple,
    required this.widths,
    required this.defaultWidth,
  });

  final bool twoByte;
  final bool directUnicode;
  final Map<int, String>? unicode;
  final Map<int, String>? simple;
  final Map<int, double> widths;
  final double defaultWidth;

  factory PdfFont.load(PdfDocument doc, Object? fontRef) {
    final dict = doc.dict(fontRef) ?? <String, Object?>{};
    final subtype = doc.name(dict['Subtype']);
    final cmap = _readToUnicode(doc, dict['ToUnicode']);
    if (subtype == 'Type0') {
      final descendants =
          doc.array(dict['DescendantFonts']) ?? const <Object?>[];
      final descendant = descendants.isEmpty
          ? null
          : doc.dict(descendants.first);
      final widths = <int, double>{};
      var defaultWidth = 1000.0;
      if (descendant != null) {
        defaultWidth = doc.number(descendant['DW'])?.toDouble() ?? 1000.0;
        _readCidWidths(doc, doc.array(descendant['W']), widths);
      }
      final encoding = doc.name(dict['Encoding']) ?? '';
      return PdfFont._(
        twoByte: true,
        directUnicode:
            cmap == null &&
            (encoding.contains('UCS2') || encoding.contains('UTF16')),
        unicode: cmap?.map,
        simple: null,
        widths: widths,
        defaultWidth: defaultWidth / 1000,
      );
    }
    final widths = <int, double>{};
    final first = doc.number(dict['FirstChar'])?.toInt() ?? 0;
    final list = doc.array(dict['Widths']);
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        final w = doc.number(list[i]);
        if (w != null) widths[first + i] = w / 1000;
      }
    }
    final descriptor = doc.dict(dict['FontDescriptor']);
    final missing = doc.number(descriptor?['MissingWidth'])?.toDouble() ?? 0.0;
    return PdfFont._(
      twoByte: false,
      directUnicode: false,
      unicode: cmap?.map,
      simple: _buildEncoding(doc, dict['Encoding']),
      widths: widths,
      defaultWidth: widths.isEmpty ? 0.5 : missing / 1000,
    );
  }

  static String? _glyph(String name) {
    final known = pdfGlyphNames[name];
    if (known != null) return String.fromCharCode(known);
    if (name.startsWith('uni') && name.length >= 7) {
      final v = int.tryParse(name.substring(3, 7), radix: 16);
      if (v != null) return String.fromCharCode(v);
    }
    if (name.startsWith('u') && name.length >= 5 && name.length <= 7) {
      final v = int.tryParse(name.substring(1), radix: 16);
      if (v != null && v <= 0x10FFFF) return String.fromCharCode(v);
    }
    final dot = name.indexOf('.');
    if (dot > 0) return _glyph(name.substring(0, dot));
    return null;
  }

  static Map<int, String> _buildEncoding(PdfDocument doc, Object? value) {
    final map = <int, String>{};
    var base = 'WinAnsiEncoding';
    List<Object?>? differences;
    final resolved = doc.resolve(value);
    if (resolved is PdfName) {
      base = resolved.value;
    } else {
      final d = doc.dict(resolved);
      if (d != null) {
        base = doc.name(d['BaseEncoding']) ?? base;
        differences = doc.array(d['Differences']);
      }
    }
    for (var c = 32; c < 127; c++) {
      map[c] = String.fromCharCode(c);
    }
    if (base == 'MacRomanEncoding') {
      for (var i = 0; i < 128; i++) {
        map[128 + i] = pdfMacRomanHigh[i];
      }
    } else {
      for (var i = 0; i < pdfWinAnsiC1.length; i++) {
        map[0x80 + i] = String.fromCharCode(pdfWinAnsiC1[i]);
      }
      for (var c = 0xA0; c <= 0xFF; c++) {
        map[c] = String.fromCharCode(c);
      }
    }
    if (differences != null) {
      var code = 0;
      for (final item in differences) {
        final r = doc.resolve(item);
        if (r is num) {
          code = r.toInt();
        } else if (r is PdfName) {
          final s = _glyph(r.value);
          if (s != null) map[code] = s;
          code++;
        }
      }
    }
    return map;
  }

  static int _code(Uint8List bytes) {
    var v = 0;
    for (final b in bytes) {
      v = (v << 8) | b;
    }
    return v;
  }

  static String _utf16(Uint8List bytes) {
    if (bytes.length == 1) return String.fromCharCode(bytes[0]);
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static String _offset(String base, int delta) {
    if (base.isEmpty) return '';
    final last = base.codeUnitAt(base.length - 1) + delta;
    return base.substring(0, base.length - 1) + String.fromCharCode(last);
  }

  static _CMap? _readToUnicode(PdfDocument doc, Object? ref) {
    final stream = doc.stream(ref);
    if (stream == null) return null;
    final bytes = doc.decode(stream);
    if (bytes == null) return null;
    final lexer = PdfLexer(bytes);
    final map = <int, String>{};
    var codeBytes = 0;
    final stack = <Object?>[];
    while (true) {
      final t = lexer.read();
      if (identical(t, pdfEof)) break;
      if (t is! PdfOp) {
        stack.add(t);
        continue;
      }
      switch (t.value) {
        case 'endcodespacerange':
          if (codeBytes == 0 && stack.isNotEmpty) {
            final first = stack.first;
            if (first is PdfString) codeBytes = first.bytes.length;
          }
        case 'endbfchar':
          for (var i = 0; i + 1 < stack.length; i += 2) {
            final src = stack[i];
            final dst = stack[i + 1];
            if (src is PdfString && dst is PdfString) {
              map[_code(src.bytes)] = _utf16(dst.bytes);
            }
          }
        case 'endbfrange':
          for (var i = 0; i + 2 < stack.length; i += 3) {
            final lo = stack[i];
            final hi = stack[i + 1];
            final dst = stack[i + 2];
            if (lo is! PdfString || hi is! PdfString) continue;
            final from = _code(lo.bytes);
            final to = _code(hi.bytes);
            if (dst is PdfString) {
              final base = _utf16(dst.bytes);
              for (var c = from; c <= to && c - from < 65536; c++) {
                map[c] = _offset(base, c - from);
              }
            } else if (dst is List<Object?>) {
              for (var k = 0; k < dst.length && from + k <= to; k++) {
                final d = dst[k];
                if (d is PdfString) map[from + k] = _utf16(d.bytes);
              }
            }
          }
      }
      stack.clear();
    }
    if (map.isEmpty) return null;
    if (codeBytes == 0) {
      codeBytes = map.keys.any((k) => k > 255) ? 2 : 1;
    }
    return _CMap(map, codeBytes);
  }

  static void _readCidWidths(
    PdfDocument doc,
    List<Object?>? w,
    Map<int, double> out,
  ) {
    if (w == null) return;
    var i = 0;
    while (i < w.length) {
      final first = doc.number(w[i])?.toInt();
      if (first == null || i + 1 >= w.length) break;
      final next = doc.resolve(w[i + 1]);
      if (next is List<Object?>) {
        for (var k = 0; k < next.length; k++) {
          final v = doc.number(next[k]);
          if (v != null) out[first + k] = v / 1000;
        }
        i += 2;
      } else {
        final last = doc.number(next)?.toInt();
        final v = i + 2 < w.length ? doc.number(w[i + 2]) : null;
        if (last != null && v != null) {
          for (var c = first; c <= last && c - first < 70000; c++) {
            out[c] = v / 1000;
          }
        }
        i += 3;
      }
    }
  }

  PdfShown show(Uint8List bytes) {
    final out = StringBuffer();
    var width = 0.0;
    var codes = 0;
    var spaces = 0;
    final step = twoByte ? 2 : 1;
    for (var i = 0; i + step <= bytes.length; i += step) {
      final code = twoByte ? (bytes[i] << 8) | bytes[i + 1] : bytes[i];
      codes++;
      if (!twoByte && code == 32) spaces++;
      width += widths[code] ?? defaultWidth;
      final text = unicode?[code] ?? simple?[code];
      if (text != null) {
        out.write(text);
      } else if (directUnicode && code > 31) {
        out.writeCharCode(code);
      }
    }
    return PdfShown(out.toString(), width, codes, spaces);
  }
}

class PdfPiece {
  const PdfPiece(this.text, this.x, this.y, this.size, this.end);

  final String text;
  final double x;
  final double y;
  final double size;
  final double end;
}

class PdfImagePiece {
  const PdfImagePiece(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final double width;
  final double height;
}

class _State {
  _State(this.ctm);

  List<double> ctm;
  PdfFont? font;
  double size = 0;
  double tc = 0;
  double tw = 0;
  double tz = 1;
  double tl = 0;
  double rise = 0;

  _State copy() {
    return _State(List<double>.of(ctm))
      ..font = font
      ..size = size
      ..tc = tc
      ..tw = tw
      ..tz = tz
      ..tl = tl
      ..rise = rise;
  }
}

List<double> _identity() => <double>[1, 0, 0, 1, 0, 0];

List<double> _mul(List<double> a, List<double> b) {
  return <double>[
    a[0] * b[0] + a[1] * b[2],
    a[0] * b[1] + a[1] * b[3],
    a[2] * b[0] + a[3] * b[2],
    a[2] * b[1] + a[3] * b[3],
    a[4] * b[0] + a[5] * b[2] + b[4],
    a[4] * b[1] + a[5] * b[3] + b[5],
  ];
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

class PdfInterpreter {
  PdfInterpreter(this.doc, this.items);

  final PdfDocument doc;
  List<Object> items;
  final Map<int, PdfFont> _fonts = <int, PdfFont>{};
  int _depth = 0;

  PdfFont? _font(Map<String, Object?>? resources, String name) {
    final fonts = doc.dict(resources?['Font']);
    if (fonts == null) return null;
    final entry = fonts[name];
    if (entry == null) return null;
    if (entry is PdfRef) {
      return _fonts.putIfAbsent(entry.id, () => PdfFont.load(doc, entry));
    }
    return PdfFont.load(doc, entry);
  }

  void run(
    Uint8List content,
    Map<String, Object?>? resources,
    List<double> base,
  ) {
    final lexer = PdfLexer(content);
    final operands = <Object?>[];
    var gs = _State(base);
    final saved = <_State>[];
    var tm = _identity();
    var tlm = _identity();

    double n(int i) {
      if (i >= operands.length) return 0;
      final v = operands[i];
      return v is num ? v.toDouble() : 0;
    }

    void show(List<Object?> parts) {
      final font = gs.font;
      if (font == null) return;
      final text = StringBuffer();
      var tx = 0.0;
      for (final part in parts) {
        if (part is PdfString) {
          final shown = font.show(part.bytes);
          text.write(shown.text);
          tx +=
              (shown.width * gs.size +
                  shown.codes * gs.tc +
                  shown.spaces * gs.tw) *
              gs.tz;
        } else if (part is num) {
          tx -= part / 1000 * gs.size * gs.tz;
          if (part <= -180 && text.isNotEmpty) text.write(' ');
        }
      }
      final value = text.toString();
      if (value.trim().isNotEmpty) {
        final c = gs.ctm;
        final ax = tm[0] * c[0] + tm[1] * c[2];
        final ay = tm[0] * c[1] + tm[1] * c[3];
        if (ax.abs() >= ay.abs()) {
          final ox = tm[2] * gs.rise + tm[4];
          final oy = tm[3] * gs.rise + tm[5];
          final x = ox * c[0] + oy * c[2] + c[4];
          final y = ox * c[1] + oy * c[3] + c[5];
          var size = gs.size * _hypot(tm[2], tm[3]) * _hypot(c[2], c[3]);
          if (size <= 0) size = gs.size.abs();
          final scale = _hypot(tm[0], tm[1]) * _hypot(c[0], c[1]);
          items.add(PdfPiece(value, x, y, size, x + tx * scale));
        }
      }
      tm = _mul(<double>[1, 0, 0, 1, tx, 0], tm);
    }

    void nextLine() {
      tlm = _mul(<double>[1, 0, 0, 1, 0, -gs.tl], tlm);
      tm = tlm;
    }

    while (true) {
      final t = lexer.read();
      if (identical(t, pdfEof)) break;
      if (t is! PdfOp) {
        operands.add(t);
        if (operands.length > 200) operands.removeAt(0);
        continue;
      }
      switch (t.value) {
        case 'q':
          saved.add(gs.copy());
        case 'Q':
          if (saved.isNotEmpty) gs = saved.removeLast();
        case 'cm':
          if (operands.length >= 6) {
            gs.ctm = _mul(<double>[n(0), n(1), n(2), n(3), n(4), n(5)], gs.ctm);
          }
        case 'BT':
          tm = _identity();
          tlm = _identity();
        case 'Tf':
          if (operands.isNotEmpty) {
            final name = operands.first;
            if (name is PdfName) gs.font = _font(resources, name.value);
            gs.size = n(1);
          }
        case 'Tc':
          gs.tc = n(0);
        case 'Tw':
          gs.tw = n(0);
        case 'Tz':
          gs.tz = n(0) / 100;
        case 'TL':
          gs.tl = n(0);
        case 'Ts':
          gs.rise = n(0);
        case 'Td':
          tlm = _mul(<double>[1, 0, 0, 1, n(0), n(1)], tlm);
          tm = tlm;
        case 'TD':
          gs.tl = -n(1);
          tlm = _mul(<double>[1, 0, 0, 1, n(0), n(1)], tlm);
          tm = tlm;
        case 'Tm':
          if (operands.length >= 6) {
            tlm = <double>[n(0), n(1), n(2), n(3), n(4), n(5)];
            tm = tlm;
          }
        case 'T*':
          nextLine();
        case 'Tj':
          if (operands.isNotEmpty) show(<Object?>[operands.last]);
        case 'TJ':
          if (operands.isNotEmpty) {
            final array = operands.last;
            if (array is List<Object?>) show(array);
          }
        case "'":
          nextLine();
          if (operands.isNotEmpty) show(<Object?>[operands.last]);
        case '"':
          gs.tw = n(0);
          gs.tc = n(1);
          nextLine();
          if (operands.length >= 3) show(<Object?>[operands[2]]);
        case 'Do':
          if (operands.isNotEmpty) {
            final name = operands.last;
            if (name is PdfName) _xobject(name.value, resources, gs.ctm);
          }
        case 'BI':
          lexer.pos = _skipInline(content, lexer.pos);
      }
      operands.clear();
    }
  }

  static int _skipInline(Uint8List d, int from) {
    var i = from;
    while (i + 2 < d.length) {
      if (d[i] == 0x49 &&
          d[i + 1] == 0x44 &&
          (i == 0 || PdfLexer.isSpace(d[i - 1])) &&
          PdfLexer.isSpace(d[i + 2])) {
        break;
      }
      i++;
    }
    i += 3;
    while (i + 2 < d.length) {
      if (d[i] == 0x45 &&
          d[i + 1] == 0x49 &&
          PdfLexer.isSpace(d[i - 1]) &&
          PdfLexer.isSpace(d[i + 2])) {
        return i + 2;
      }
      i++;
    }
    return d.length;
  }

  void _xobject(
    String name,
    Map<String, Object?>? resources,
    List<double> ctm,
  ) {
    final xobjects = doc.dict(resources?['XObject']);
    final stream = doc.stream(xobjects?[name]);
    if (stream == null) return;
    final subtype = doc.name(stream.dict['Subtype']);
    if (subtype == 'Form') {
      if (_depth >= 6) return;
      final data = doc.decode(stream);
      if (data == null) return;
      final matrixValues = doc.array(stream.dict['Matrix']);
      var matrix = _identity();
      if (matrixValues != null && matrixValues.length >= 6) {
        matrix = <double>[
          for (var i = 0; i < 6; i++)
            doc.number(matrixValues[i])?.toDouble() ?? 0.0,
        ];
      }
      final inner = doc.dict(stream.dict['Resources']) ?? resources;
      _depth++;
      run(data, inner, _mul(matrix, ctm));
      _depth--;
    } else if (subtype == 'Image') {
      _image(stream, ctm);
    }
  }

  int? _channels(Object? colorSpace) {
    final r = doc.resolve(colorSpace);
    if (r is PdfName) {
      if (r.value == 'DeviceRGB' || r.value == 'RGB' || r.value == 'CalRGB')
        return 3;
      if (r.value == 'DeviceGray' || r.value == 'G' || r.value == 'CalGray')
        return 1;
      return null;
    }
    if (r is List<Object?> && r.isNotEmpty) {
      final kind = doc.name(r.first);
      if (kind == 'ICCBased' && r.length > 1) {
        final profile = doc.dict(r[1]);
        final count = doc.number(profile?['N'])?.toInt();
        return count == 1 || count == 3 ? count : null;
      }
      if (kind == 'CalRGB') return 3;
      if (kind == 'CalGray') return 1;
    }
    return null;
  }

  void _image(PdfStream stream, List<double> ctm) {
    final width = _hypot(ctm[0], ctm[1]);
    final height = _hypot(ctm[2], ctm[3]);
    if (width < 24 || height < 24) return;
    if (doc.resolve(stream.dict['ImageMask']) == true) return;
    final jpeg = doc.jpeg(stream);
    if (jpeg != null) {
      items.add(PdfImagePiece(jpeg, width, height));
      return;
    }
    final w = doc.number(stream.dict['Width'])?.toInt();
    final h = doc.number(stream.dict['Height'])?.toInt();
    final bits = doc.number(stream.dict['BitsPerComponent'])?.toInt() ?? 8;
    final channels = _channels(stream.dict['ColorSpace']);
    if (w == null || h == null || channels == null || bits != 8) return;
    if (w <= 0 || h <= 0 || w * h > 12000000) return;
    final pixels = doc.decode(stream);
    if (pixels == null || pixels.length < w * h * channels) return;
    items.add(PdfImagePiece(_png(w, h, channels, pixels), width, height));
  }
}

List<int>? _crcTable;

int _crc32(List<int> bytes) {
  var table = _crcTable;
  if (table == null) {
    table = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    _crcTable = table;
  }
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  final body = BytesBuilder()
    ..add(type.codeUnits)
    ..add(data);
  final bytes = body.takeBytes();
  out.add(bytes);
  final crc = ByteData(4)..setUint32(0, _crc32(bytes));
  out.add(crc.buffer.asUint8List());
}

Uint8List _png(int width, int height, int channels, Uint8List pixels) {
  final stride = width * channels;
  final raw = Uint8List(height * (stride + 1));
  for (var y = 0; y < height; y++) {
    final at = y * (stride + 1);
    raw.setRange(at + 1, at + 1 + stride, pixels, y * stride);
  }
  final deflated = Uint8List.fromList(ZLibEncoder().convert(raw));
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, channels == 3 ? 2 : 0);
  final out = BytesBuilder()
    ..add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  _chunk(out, 'IDAT', deflated);
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}
