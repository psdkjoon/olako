import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class PdfName {
  const PdfName(this.value);

  final String value;
}

class PdfOp {
  const PdfOp(this.value);

  final String value;
}

class PdfRef {
  const PdfRef(this.id);

  final int id;
}

class PdfString {
  const PdfString(this.bytes);

  final Uint8List bytes;
}

class PdfStream {
  PdfStream(this.dict, this.raw);

  final Map<String, Object?> dict;
  final Uint8List raw;
}

final Object pdfEof = Object();
final Object _endArray = Object();
final Object _endDict = Object();

class PdfLexer {
  PdfLexer(this.data, {this.pos = 0, this.refs = false});

  final Uint8List data;
  final bool refs;
  int pos;

  static bool isSpace(int c) =>
      c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;

  static bool isDelimiter(int c) =>
      c == 0x28 ||
      c == 0x29 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x5B ||
      c == 0x5D ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x2F ||
      c == 0x25;

  void skipSpace() {
    final n = data.length;
    while (pos < n) {
      final c = data[pos];
      if (isSpace(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < n && data[pos] != 10 && data[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  Object? read() {
    skipSpace();
    if (pos >= data.length) return pdfEof;
    final c = data[pos];
    if (c == 0x2F) return _name();
    if (c == 0x28) return _literal();
    if (c == 0x3C) {
      if (pos + 1 < data.length && data[pos + 1] == 0x3C) {
        pos += 2;
        return _dict();
      }
      return _hex();
    }
    if (c == 0x3E) {
      if (pos + 1 < data.length && data[pos + 1] == 0x3E) {
        pos += 2;
        return _endDict;
      }
      pos++;
      return read();
    }
    if (c == 0x5B) {
      pos++;
      return _array();
    }
    if (c == 0x5D) {
      pos++;
      return _endArray;
    }
    if (c == 0x7B || c == 0x7D || c == 0x29) {
      pos++;
      return read();
    }
    return _token();
  }

  Object? _token() {
    final start = pos;
    final n = data.length;
    while (pos < n) {
      final c = data[pos];
      if (isSpace(c) || isDelimiter(c)) break;
      pos++;
    }
    if (pos == start) {
      pos++;
      return read();
    }
    final text = String.fromCharCodes(data, start, pos);
    final first = data[start];
    if (first == 0x2B ||
        first == 0x2D ||
        first == 0x2E ||
        (first >= 0x30 && first <= 0x39)) {
      final number = int.tryParse(text) ?? double.tryParse(text);
      if (number != null) {
        if (refs && number is int && number >= 0) {
          final ref = _tryRef(number);
          if (ref != null) return ref;
        }
        return number;
      }
    }
    switch (text) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    return PdfOp(text);
  }

  PdfRef? _tryRef(int id) {
    final save = pos;
    skipSpace();
    final start = pos;
    while (pos < data.length && data[pos] >= 0x30 && data[pos] <= 0x39) {
      pos++;
    }
    if (pos > start) {
      skipSpace();
      if (pos < data.length && data[pos] == 0x52) {
        final after = pos + 1;
        if (after >= data.length ||
            isSpace(data[after]) ||
            isDelimiter(data[after])) {
          pos = after;
          return PdfRef(id);
        }
      }
    }
    pos = save;
    return null;
  }

  PdfName _name() {
    pos++;
    final out = StringBuffer();
    final n = data.length;
    while (pos < n) {
      final c = data[pos];
      if (isSpace(c) || isDelimiter(c)) break;
      if (c == 0x23 && pos + 2 < n) {
        final v = int.tryParse(
          String.fromCharCodes(data, pos + 1, pos + 3),
          radix: 16,
        );
        if (v != null) {
          out.writeCharCode(v);
          pos += 3;
          continue;
        }
      }
      out.writeCharCode(c);
      pos++;
    }
    return PdfName(out.toString());
  }

  PdfString _literal() {
    pos++;
    final out = BytesBuilder();
    var depth = 1;
    final n = data.length;
    while (pos < n) {
      final c = data[pos++];
      if (c == 0x5C) {
        if (pos >= n) break;
        final e = data[pos++];
        switch (e) {
          case 0x6E:
            out.addByte(10);
          case 0x72:
            out.addByte(13);
          case 0x74:
            out.addByte(9);
          case 0x62:
            out.addByte(8);
          case 0x66:
            out.addByte(12);
          case 0x0D:
            if (pos < n && data[pos] == 0x0A) pos++;
          case 0x0A:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              var count = 1;
              while (count < 3 &&
                  pos < n &&
                  data[pos] >= 0x30 &&
                  data[pos] <= 0x37) {
                v = v * 8 + data[pos] - 0x30;
                pos++;
                count++;
              }
              out.addByte(v & 0xFF);
            } else {
              out.addByte(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.addByte(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.addByte(c);
      } else {
        out.addByte(c);
      }
    }
    return PdfString(out.takeBytes());
  }

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  PdfString _hex() {
    pos++;
    final out = BytesBuilder();
    int? high;
    final n = data.length;
    while (pos < n) {
      final c = data[pos++];
      if (c == 0x3E) break;
      final v = _hexValue(c);
      if (v < 0) continue;
      if (high == null) {
        high = v;
      } else {
        out.addByte(high * 16 + v);
        high = null;
      }
    }
    if (high != null) out.addByte(high * 16);
    return PdfString(out.takeBytes());
  }

  List<Object?> _array() {
    final out = <Object?>[];
    while (true) {
      final v = read();
      if (identical(v, _endArray) || identical(v, pdfEof)) break;
      if (identical(v, _endDict)) continue;
      out.add(v);
    }
    return out;
  }

  Map<String, Object?> _dict() {
    final out = <String, Object?>{};
    while (true) {
      final key = read();
      if (identical(key, _endDict) || identical(key, pdfEof)) break;
      if (key is! PdfName) continue;
      final value = read();
      if (identical(value, _endDict) || identical(value, pdfEof)) break;
      if (identical(value, _endArray)) continue;
      out[key.value] = value;
    }
    return out;
  }
}

class _Collector implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder();

  @override
  void add(List<int> data) => builder.add(data);

  @override
  void close() {}
}

class _ObjectStream {
  _ObjectStream(this.bytes, this.first, this.numbers, this.offsets);

  final Uint8List bytes;
  final int first;
  final List<int> numbers;
  final List<int> offsets;
}

class PdfDocument {
  PdfDocument(this.data) : _text = String.fromCharCodes(data) {
    _index();
  }

  final Uint8List data;
  final String _text;
  final Map<int, int> _offsets = <int, int>{};
  final Map<int, ({int stream, int index})> _packed =
      <int, ({int stream, int index})>{};
  final Map<int, _ObjectStream> _streams = <int, _ObjectStream>{};
  final Map<int, Object?> _cache = <int, Object?>{};
  List<MapEntry<int, int>> _owners = <MapEntry<int, int>>[];

  Iterable<int> get objectIds {
    final ids = <int>{..._offsets.keys, ..._packed.keys};
    return ids.toList()..sort();
  }

  void _index() {
    for (final m in RegExp(r'(\d+)\s+(\d+)\s+obj\b').allMatches(_text)) {
      final id = int.tryParse(m.group(1)!);
      if (id != null) _offsets[id] = m.end;
    }
    _owners = _offsets.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final m in RegExp(r'/Type\s*/ObjStm').allMatches(_text)) {
      final id = _ownerOf(m.start);
      if (id != null) _registerStream(id);
    }
  }

  int? _ownerOf(int position) {
    var low = 0;
    var high = _owners.length - 1;
    int? best;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_owners[mid].value <= position) {
        best = _owners[mid].key;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }

  void _registerStream(int id) {
    if (_streams.containsKey(id)) return;
    final stream = object(id);
    if (stream is! PdfStream) return;
    final count = number(stream.dict['N'])?.toInt();
    final first = number(stream.dict['First'])?.toInt();
    if (count == null || first == null || count > 200000) return;
    final bytes = decode(stream);
    if (bytes == null) return;
    final lexer = PdfLexer(bytes);
    final numbers = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      final n = lexer.read();
      final o = lexer.read();
      if (n is! int || o is! int) break;
      numbers.add(n);
      offsets.add(o);
    }
    _streams[id] = _ObjectStream(bytes, first, numbers, offsets);
    for (var i = 0; i < numbers.length; i++) {
      if (!_offsets.containsKey(numbers[i])) {
        _packed[numbers[i]] = (stream: id, index: i);
      }
    }
  }

  Object? object(int id) {
    if (_cache.containsKey(id)) return _cache[id];
    _cache[id] = null;
    Object? value;
    final offset = _offsets[id];
    final packed = _packed[id];
    if (offset != null) {
      value = _parseIndirect(offset);
    } else if (packed != null) {
      final holder = _streams[packed.stream];
      if (holder != null) {
        final start = holder.first + holder.offsets[packed.index];
        if (start >= 0 && start < holder.bytes.length) {
          final read = PdfLexer(holder.bytes, pos: start, refs: true).read();
          value = identical(read, pdfEof) ? null : read;
        }
      }
    }
    _cache[id] = value;
    return value;
  }

  bool _startsWith(int at, String word) {
    if (at < 0 || at + word.length > data.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (data[at + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool _endstreamFollows(int at) {
    var p = at;
    while (p < data.length && PdfLexer.isSpace(data[p])) {
      p++;
    }
    return _startsWith(p, 'endstream');
  }

  Object? _parseIndirect(int offset) {
    final lexer = PdfLexer(data, pos: offset, refs: true);
    final value = lexer.read();
    if (identical(value, pdfEof)) return null;
    if (value is! Map<String, Object?>) return value;
    lexer.skipSpace();
    if (!_startsWith(lexer.pos, 'stream')) return value;
    var p = lexer.pos + 6;
    if (p < data.length && data[p] == 13) {
      p++;
      if (p < data.length && data[p] == 10) p++;
    } else if (p < data.length && data[p] == 10) {
      p++;
    }
    final length = number(value['Length'])?.toInt();
    int end;
    if (length != null &&
        length >= 0 &&
        p + length <= data.length &&
        _endstreamFollows(p + length)) {
      end = p + length;
    } else {
      final found = _text.indexOf('endstream', p);
      end = found < 0 ? data.length : found;
      if (end > p && data[end - 1] == 10) end--;
      if (end > p && data[end - 1] == 13) end--;
    }
    return PdfStream(value, Uint8List.sublistView(data, p, end));
  }

  Object? resolve(Object? value) {
    var current = value;
    var guard = 0;
    while (current is PdfRef && guard < 24) {
      current = object(current.id);
      guard++;
    }
    return current is PdfRef ? null : current;
  }

  Map<String, Object?>? dict(Object? value) {
    final r = resolve(value);
    if (r is PdfStream) return r.dict;
    if (r is Map<String, Object?>) return r;
    return null;
  }

  List<Object?>? array(Object? value) {
    final r = resolve(value);
    return r is List<Object?> ? r : null;
  }

  num? number(Object? value) {
    final r = resolve(value);
    return r is num ? r : null;
  }

  String? name(Object? value) {
    final r = resolve(value);
    return r is PdfName ? r.value : null;
  }

  PdfStream? stream(Object? value) {
    final r = resolve(value);
    return r is PdfStream ? r : null;
  }

  Map<String, Object?>? trailer() {
    var idx = _text.lastIndexOf('trailer');
    while (idx >= 0) {
      final v = PdfLexer(data, pos: idx + 7, refs: true).read();
      if (v is Map<String, Object?> && v.containsKey('Root')) return v;
      if (idx == 0) break;
      idx = _text.lastIndexOf('trailer', idx - 1);
    }
    Map<String, Object?>? found;
    for (final m in RegExp(r'/Type\s*/XRef').allMatches(_text)) {
      final id = _ownerOf(m.start);
      if (id == null) continue;
      final d = dict(object(id));
      if (d != null && d.containsKey('Root')) found = d;
    }
    return found;
  }

  Uint8List? decode(PdfStream stream) => _decodeFilters(stream, false);

  Uint8List? jpeg(PdfStream stream) => _decodeFilters(stream, true);

  Uint8List? _decodeFilters(PdfStream stream, bool wantJpeg) {
    final filterValue = resolve(stream.dict['Filter'] ?? stream.dict['F']);
    final filters = <String>[];
    if (filterValue is PdfName) {
      filters.add(filterValue.value);
    } else if (filterValue is List<Object?>) {
      for (final f in filterValue) {
        final n = name(f);
        if (n != null) filters.add(n);
      }
    }
    final parmsValue = resolve(stream.dict['DecodeParms'] ?? stream.dict['DP']);
    final parms = <Map<String, Object?>?>[];
    if (parmsValue is List<Object?>) {
      for (final p in parmsValue) {
        parms.add(dict(p));
      }
    } else {
      parms.add(dict(parmsValue));
    }
    var bytes = stream.raw;
    for (var i = 0; i < filters.length; i++) {
      final p = i < parms.length ? parms[i] : null;
      switch (filters[i]) {
        case 'FlateDecode':
        case 'Fl':
          bytes = _flate(bytes, p);
        case 'ASCIIHexDecode':
        case 'AHx':
          bytes = _asciiHex(bytes);
        case 'ASCII85Decode':
        case 'A85':
          bytes = _ascii85(bytes);
        case 'RunLengthDecode':
        case 'RL':
          bytes = _runLength(bytes);
        case 'DCTDecode':
        case 'DCT':
          return wantJpeg && i == filters.length - 1 ? bytes : null;
        default:
          return null;
      }
    }
    return wantJpeg ? null : bytes;
  }

  Uint8List _flate(Uint8List input, Map<String, Object?>? parms) {
    var out = _inflate(input);
    final predictor = number(parms?['Predictor'])?.toInt() ?? 1;
    if (predictor >= 10) {
      out = _pngPredictor(
        out,
        number(parms?['Columns'])?.toInt() ?? 1,
        number(parms?['Colors'])?.toInt() ?? 1,
        number(parms?['BitsPerComponent'])?.toInt() ?? 8,
      );
    }
    return out;
  }

  static Uint8List _run(
    Converter<List<int>, List<int>> converter,
    Uint8List input,
  ) {
    final collector = _Collector();
    final sink = converter.startChunkedConversion(collector);
    try {
      sink.add(input);
      sink.close();
    } on Object {
      return collector.builder.takeBytes();
    }
    return collector.builder.takeBytes();
  }

  static Uint8List _inflate(Uint8List input) {
    final normal = _run(ZLibDecoder(), input);
    if (normal.isNotEmpty || input.length < 3) return normal;
    return _run(ZLibDecoder(raw: true), Uint8List.sublistView(input, 2));
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  static Uint8List _pngPredictor(
    Uint8List data,
    int columns,
    int colors,
    int bits,
  ) {
    final bpp = math.max(1, (colors * bits + 7) ~/ 8);
    final rowBytes = (columns * colors * bits + 7) ~/ 8;
    if (rowBytes <= 0) return data;
    final stride = rowBytes + 1;
    final rows = data.length ~/ stride;
    final out = Uint8List(rows * rowBytes);
    for (var r = 0; r < rows; r++) {
      final filter = data[r * stride];
      final src = r * stride + 1;
      final dst = r * rowBytes;
      final prev = dst - rowBytes;
      for (var i = 0; i < rowBytes; i++) {
        final x = data[src + i];
        final a = i >= bpp ? out[dst + i - bpp] : 0;
        final b = r > 0 ? out[prev + i] : 0;
        final c = (i >= bpp && r > 0) ? out[prev + i - bpp] : 0;
        int v;
        switch (filter) {
          case 1:
            v = x + a;
          case 2:
            v = x + b;
          case 3:
            v = x + ((a + b) >> 1);
          case 4:
            v = x + _paeth(a, b, c);
          default:
            v = x;
        }
        out[dst + i] = v & 0xFF;
      }
    }
    return out;
  }

  static Uint8List _asciiHex(Uint8List input) {
    final out = BytesBuilder();
    int? high;
    for (final c in input) {
      if (c == 0x3E) break;
      final v = PdfLexer._hexValue(c);
      if (v < 0) continue;
      if (high == null) {
        high = v;
      } else {
        out.addByte(high * 16 + v);
        high = null;
      }
    }
    if (high != null) out.addByte(high * 16);
    return out.takeBytes();
  }

  static Uint8List _ascii85(Uint8List input) {
    final out = BytesBuilder();
    final group = List<int>.filled(5, 0);
    var count = 0;
    var i = 0;
    if (input.length >= 2 && input[0] == 0x3C && input[1] == 0x7E) i = 2;
    void emit(int bytes) {
      var v = 0;
      for (var k = 0; k < 5; k++) {
        v = v * 85 + group[k];
      }
      final all = <int>[
        (v >> 24) & 255,
        (v >> 16) & 255,
        (v >> 8) & 255,
        v & 255,
      ];
      for (var k = 0; k < bytes; k++) {
        out.addByte(all[k]);
      }
    }

    for (; i < input.length; i++) {
      final c = input[i];
      if (c == 0x7E) break;
      if (PdfLexer.isSpace(c)) continue;
      if (c == 0x7A && count == 0) {
        out.add(const <int>[0, 0, 0, 0]);
        continue;
      }
      if (c < 0x21 || c > 0x75) continue;
      group[count++] = c - 0x21;
      if (count == 5) {
        emit(4);
        count = 0;
      }
    }
    if (count > 1) {
      for (var k = count; k < 5; k++) {
        group[k] = 84;
      }
      emit(count - 1);
    }
    return out.takeBytes();
  }

  static Uint8List _runLength(Uint8List input) {
    final out = BytesBuilder();
    var i = 0;
    while (i < input.length) {
      final length = input[i++];
      if (length == 128) break;
      if (length < 128) {
        final end = math.min(input.length, i + length + 1);
        out.add(Uint8List.sublistView(input, i, end));
        i = end;
      } else if (i < input.length) {
        final value = input[i++];
        out.add(List<int>.filled(257 - length, value));
      }
    }
    return out.takeBytes();
  }
}
