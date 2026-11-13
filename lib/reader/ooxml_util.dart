import 'package:olako/reader/xml_lite.dart';
import 'package:olako/reader/zip_archive.dart';

class Relationship {
  const Relationship({
    required this.id,
    required this.type,
    required this.target,
    required this.external,
  });

  final String id;
  final String type;
  final String target;
  final bool external;
}

Map<String, Relationship> readRelationships(ZipArchive zip, String part) {
  final slash = part.lastIndexOf('/');
  final dir = slash < 0 ? '' : part.substring(0, slash + 1);
  final file = slash < 0 ? part : part.substring(slash + 1);
  final text = zip.readString('${dir}_rels/$file.rels');
  final result = <String, Relationship>{};
  if (text == null) return result;
  final XmlElement root;
  try {
    root = parseXml(text);
  } on FormatException {
    return result;
  }
  for (final r in root.childrenNamed('Relationship')) {
    final id = r.attr('Id');
    final target = r.attr('Target');
    if (id == null || target == null) continue;
    result[id] = Relationship(
      id: id,
      type: r.attr('Type') ?? '',
      target: target,
      external: r.attr('TargetMode') == 'External',
    );
  }
  return result;
}

String resolvePartPath(String basePart, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final slash = basePart.lastIndexOf('/');
  final dir = slash < 0 ? '' : basePart.substring(0, slash);
  final segments = <String>[if (dir.isNotEmpty) ...dir.split('/')];
  for (final part in target.split('/')) {
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      segments.add(part);
    }
  }
  return segments.join('/');
}

String? findMainPart(ZipArchive zip) {
  final rels = readRelationships(zip, '');
  for (final r in rels.values) {
    if (r.type.endsWith('/officeDocument') && !r.external) {
      return resolvePartPath('', r.target);
    }
  }
  return null;
}

XmlElement? readXmlPart(ZipArchive zip, String? path) {
  if (path == null) return null;
  final text = zip.readString(path);
  if (text == null) return null;
  try {
    return parseXml(text);
  } on FormatException {
    return null;
  }
}

int? parseHexColor(String? value) {
  if (value == null || value.length != 6) return null;
  final number = int.tryParse(value, radix: 16);
  if (number == null) return null;
  return 0xFF000000 | number;
}

const double emuPerPoint = 12700;

String formatLetters(int n, int base) {
  if (n < 1) return '$n';
  var x = n;
  var out = '';
  while (x > 0) {
    x--;
    out = String.fromCharCode(base + x % 26) + out;
    x ~/= 26;
  }
  return out;
}

String formatRoman(int n) {
  if (n < 1 || n > 3999) return '$n';
  const values = <int>[1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const symbols = <String>[
    'M',
    'CM',
    'D',
    'CD',
    'C',
    'XC',
    'L',
    'XL',
    'X',
    'IX',
    'V',
    'IV',
    'I',
  ];
  var x = n;
  final out = StringBuffer();
  for (var i = 0; i < values.length; i++) {
    while (x >= values[i]) {
      out.write(symbols[i]);
      x -= values[i];
    }
  }
  return out.toString();
}

int clampInt(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);

double clampDouble(double value, double low, double high) =>
    value < low ? low : (value > high ? high : value);
