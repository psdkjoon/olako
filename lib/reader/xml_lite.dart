class XmlElement {
  XmlElement(this.name, this.attributes)
    : local = name.contains(':') ? name.substring(name.indexOf(':') + 1) : name;

  final String name;

  final String local;

  final Map<String, String> attributes;
  final List<XmlElement> children = <XmlElement>[];
  final List<Object> nodes = <Object>[];
  final StringBuffer _text = StringBuffer();

  String get text => _text.toString();

  String? attr(String attribute) {
    final plain = attributes[attribute];
    if (plain != null) return plain;
    final suffix = ':$attribute';
    for (final entry in attributes.entries) {
      if (entry.key.endsWith(suffix)) return entry.value;
    }
    return null;
  }

  String? prefixedAttr(String attribute) {
    final suffix = ':$attribute';
    for (final entry in attributes.entries) {
      if (entry.key.endsWith(suffix)) return entry.value;
    }
    return null;
  }

  XmlElement? child(String localName) {
    for (final c in children) {
      if (c.local == localName) return c;
    }
    return null;
  }

  Iterable<XmlElement> childrenNamed(String localName) =>
      children.where((c) => c.local == localName);

  XmlElement? path(List<String> names) {
    XmlElement? current = this;
    for (final n in names) {
      current = current?.child(n);
      if (current == null) return null;
    }
    return current;
  }

  Iterable<XmlElement> descendants(String localName) sync* {
    for (final c in children) {
      if (c.local == localName) yield c;
      yield* c.descendants(localName);
    }
  }
}

XmlElement parseXml(String source) {
  final parser = _XmlParser(source);
  final root = parser.parse();
  if (root.children.isEmpty) {
    throw const FormatException('The XML part has no content.');
  }
  return root.children.first;
}

class _XmlParser {
  _XmlParser(this._s);

  final String _s;
  int _i = 0;

  static const Map<String, String> _entities = <String, String>{
    'lt': '<',
    'gt': '>',
    'amp': '&',
    'quot': '"',
    'apos': "'",
  };

  XmlElement parse() {
    final root = XmlElement('#document', <String, String>{});
    final stack = <XmlElement>[root];
    final length = _s.length;
    if (length > 0 && _s.codeUnitAt(0) == 0xFEFF) _i = 1;
    while (_i < length) {
      final lt = _s.indexOf('<', _i);
      if (lt < 0) {
        _addText(stack.last, _s.substring(_i));
        break;
      }
      if (lt > _i) _addText(stack.last, _s.substring(_i, lt));
      _i = lt;
      if (_s.startsWith('<!--', _i)) {
        final end = _s.indexOf('-->', _i + 4);
        _i = end < 0 ? length : end + 3;
      } else if (_s.startsWith('<![CDATA[', _i)) {
        final end = _s.indexOf(']]>', _i + 9);
        final stop = end < 0 ? length : end;
        final literal = _s.substring(_i + 9, stop);
        stack.last._text.write(literal);
        stack.last.nodes.add(literal);
        _i = end < 0 ? length : end + 3;
      } else if (_s.startsWith('<?', _i)) {
        final end = _s.indexOf('?>', _i + 2);
        _i = end < 0 ? length : end + 2;
      } else if (_s.startsWith('<!', _i)) {
        _skipDeclaration();
      } else if (_s.startsWith('</', _i)) {
        final end = _s.indexOf('>', _i);
        _i = end < 0 ? length : end + 1;
        if (stack.length > 1) stack.removeLast();
      } else {
        _readStartTag(stack);
      }
    }
    return root;
  }

  void _addText(XmlElement element, String raw) {
    if (raw.isEmpty) return;
    final decoded = _decode(raw);
    element._text.write(decoded);
    element.nodes.add(decoded);
  }

  void _skipDeclaration() {
    var depth = 0;
    while (_i < _s.length) {
      final c = _s.codeUnitAt(_i);
      if (c == 0x5B) {
        depth++;
      } else if (c == 0x5D) {
        depth--;
      } else if (c == 0x3E && depth <= 0) {
        _i++;
        return;
      }
      _i++;
    }
  }

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;

  void _readStartTag(List<XmlElement> stack) {
    final length = _s.length;
    _i++;
    final nameStart = _i;
    while (_i < length) {
      final c = _s.codeUnitAt(_i);
      if (_isSpace(c) || c == 0x2F || c == 0x3E) break;
      _i++;
    }
    final name = _s.substring(nameStart, _i);
    final attributes = <String, String>{};
    var selfClosing = false;
    while (_i < length) {
      while (_i < length && _isSpace(_s.codeUnitAt(_i))) {
        _i++;
      }
      if (_i >= length) break;
      final c = _s.codeUnitAt(_i);
      if (c == 0x3E) {
        _i++;
        break;
      }
      if (c == 0x2F) {
        selfClosing = true;
        _i++;
        continue;
      }
      final keyStart = _i;
      while (_i < length) {
        final k = _s.codeUnitAt(_i);
        if (_isSpace(k) || k == 0x3D || k == 0x3E || k == 0x2F) break;
        _i++;
      }
      final key = _s.substring(keyStart, _i);
      while (_i < length && _isSpace(_s.codeUnitAt(_i))) {
        _i++;
      }
      if (_i < length && _s.codeUnitAt(_i) == 0x3D) {
        _i++;
        while (_i < length && _isSpace(_s.codeUnitAt(_i))) {
          _i++;
        }
        if (_i < length) {
          final quote = _s.codeUnitAt(_i);
          if (quote == 0x22 || quote == 0x27) {
            final end = _s.indexOf(String.fromCharCode(quote), _i + 1);
            final stop = end < 0 ? length : end;
            attributes[key] = _decode(_s.substring(_i + 1, stop));
            _i = end < 0 ? length : end + 1;
          } else {
            final valueStart = _i;
            while (_i < length) {
              final v = _s.codeUnitAt(_i);
              if (_isSpace(v) || v == 0x3E) break;
              _i++;
            }
            attributes[key] = _decode(_s.substring(valueStart, _i));
          }
        }
      } else if (key.isNotEmpty) {
        attributes[key] = '';
      } else {
        _i++;
      }
    }
    final element = XmlElement(name, attributes);
    stack.last.children.add(element);
    stack.last.nodes.add(element);
    if (!selfClosing) stack.add(element);
  }

  static String _decode(String raw) {
    if (!raw.contains('&')) return raw;
    final out = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final c = raw.codeUnitAt(i);
      if (c != 0x26) {
        out.writeCharCode(c);
        i++;
        continue;
      }
      final semi = raw.indexOf(';', i + 1);
      if (semi < 0 || semi - i > 10) {
        out.writeCharCode(c);
        i++;
        continue;
      }
      final body = raw.substring(i + 1, semi);
      String? replacement = _entities[body];
      if (replacement == null && body.startsWith('#')) {
        final isHex = body.startsWith('#x') || body.startsWith('#X');
        final number = int.tryParse(
          body.substring(isHex ? 2 : 1),
          radix: isHex ? 16 : 10,
        );
        if (number != null && number > 0 && number <= 0x10FFFF) {
          replacement = String.fromCharCode(number);
        }
      }
      if (replacement == null) {
        out.writeCharCode(c);
        i++;
      } else {
        out.write(replacement);
        i = semi + 1;
      }
    }
    return out.toString();
  }
}
