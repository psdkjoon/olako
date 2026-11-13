import 'dart:math' as math;

import 'package:flutter/services.dart';

int _lineStart(String text, int offset) {
  if (offset <= 0) return 0;
  return text.lastIndexOf('\n', offset - 1) + 1;
}

int _lineEnd(String text, int offset) {
  final index = text.indexOf('\n', offset);
  return index < 0 ? text.length : index;
}

TextSelection _range(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid) {
    return TextSelection.collapsed(offset: value.text.length);
  }
  return selection;
}

TextEditingValue wrapSelection(
  TextEditingValue value,
  String before,
  String after,
  String placeholder,
) {
  final text = value.text;
  final selection = _range(value);
  final start = selection.start;
  final end = selection.end;
  if (start == end) {
    final inserted = '$before$placeholder$after';
    return TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + placeholder.length,
      ),
    );
  }
  final wrapped =
      start >= before.length &&
      text.startsWith(before, start - before.length) &&
      text.startsWith(after, end);
  if (wrapped) {
    final cut = text.replaceRange(end, end + after.length, '');
    final plain = cut.replaceRange(start - before.length, start, '');
    return TextEditingValue(
      text: plain,
      selection: TextSelection(
        baseOffset: start - before.length,
        extentOffset: end - before.length,
      ),
    );
  }
  final selected = text.substring(start, end);
  return TextEditingValue(
    text: text.replaceRange(start, end, '$before$selected$after'),
    selection: TextSelection(
      baseOffset: start + before.length,
      extentOffset: end + before.length,
    ),
  );
}

TextEditingValue toggleLinePrefix(
  TextEditingValue value,
  String Function(int index) prefix,
  RegExp existing,
) {
  final text = value.text;
  final selection = _range(value);
  final from = _lineStart(text, selection.start);
  var last = selection.end;
  if (last > selection.start && last > 0 && text[last - 1] == '\n') last--;
  final to = _lineEnd(text, last);
  final lines = text.substring(from, to).split('\n');
  final allHave = lines.every(
    (line) => line.isEmpty || existing.hasMatch(line),
  );
  final changed = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (allHave) {
      changed.add(line.replaceFirst(existing, ''));
    } else if (existing.hasMatch(line)) {
      changed.add(line);
    } else {
      changed.add('${prefix(i)}$line');
    }
  }
  final block = changed.join('\n');
  return TextEditingValue(
    text: text.replaceRange(from, to, block),
    selection: TextSelection(
      baseOffset: from,
      extentOffset: from + block.length,
    ),
  );
}

TextEditingValue cycleHeading(TextEditingValue value) {
  final text = value.text;
  final selection = _range(value);
  final from = _lineStart(text, selection.start);
  final to = _lineEnd(text, selection.start);
  final line = text.substring(from, to);
  final match = RegExp(r'^(#{1,6}) ').firstMatch(line);
  final level = match == null ? 0 : match.group(1)!.length;
  final body = match == null ? line : line.substring(match.end);
  final next = level >= 4 ? 0 : level + 1;
  final result = next == 0 ? body : '${'#' * next} $body';
  return TextEditingValue(
    text: text.replaceRange(from, to, result),
    selection: TextSelection.collapsed(offset: from + result.length),
  );
}

TextEditingValue insertBlock(TextEditingValue value, String block) {
  final text = value.text;
  final selection = _range(value);
  final at = selection.end;
  final lead = at == 0 || text[at - 1] == '\n' ? '' : '\n';
  final inserted = '$lead$block\n';
  return TextEditingValue(
    text: text.replaceRange(at, at, inserted),
    selection: TextSelection.collapsed(offset: at + inserted.length),
  );
}

TextEditingValue insertLink(TextEditingValue value) {
  final text = value.text;
  final selection = _range(value);
  final label = selection.isCollapsed
      ? 'text'
      : text.substring(selection.start, selection.end);
  final inserted = '[$label](url)';
  final urlStart = selection.start + label.length + 3;
  return TextEditingValue(
    text: text.replaceRange(selection.start, selection.end, inserted),
    selection: TextSelection(baseOffset: urlStart, extentOffset: urlStart + 3),
  );
}

TextEditingValue shiftIndent(TextEditingValue value, {required bool outward}) {
  final text = value.text;
  final selection = _range(value);
  final from = _lineStart(text, selection.start);
  var last = selection.end;
  if (last > selection.start && last > 0 && text[last - 1] == '\n') last--;
  final to = _lineEnd(text, last);
  final lines = text.substring(from, to).split('\n');
  final changed = <String>[
    for (final line in lines)
      if (outward)
        line.startsWith('  ')
            ? line.substring(2)
            : (line.startsWith(' ') || line.startsWith('\t')
                  ? line.substring(1)
                  : line)
      else
        '  $line',
  ];
  final block = changed.join('\n');
  return TextEditingValue(
    text: text.replaceRange(from, to, block),
    selection: TextSelection(
      baseOffset: from,
      extentOffset: from + block.length,
    ),
  );
}

class ListContinuation extends TextInputFormatter {
  static final RegExp _marker = RegExp(
    r'^(\s*)([-*+] \[[ xX]\]|[-*+]|\d{1,9}[.)]) ',
  );
  static final RegExp _number = RegExp(r'^(\d{1,9})([.)])$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selection = newValue.selection;
    if (!selection.isCollapsed || selection.baseOffset < 1) return newValue;
    if (newValue.text.length != oldValue.text.length + 1) return newValue;
    final at = selection.baseOffset;
    final text = newValue.text;
    if (text[at - 1] != '\n') return newValue;
    if (text.replaceRange(at - 1, at, '') != oldValue.text) return newValue;
    final start = _lineStart(text, at - 1);
    final line = text.substring(start, at - 1);
    final match = _marker.firstMatch(line);
    if (match == null) return newValue;
    final indent = match.group(1)!;
    final bullet = match.group(2)!;
    final rest = line.substring(match.end);
    if (rest.trim().isEmpty) {
      return TextEditingValue(
        text: text.replaceRange(start, at - 1, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    }
    var next = bullet;
    final number = _number.firstMatch(bullet);
    if (number != null) {
      next =
          '${math.min(999999998, int.parse(number.group(1)!)) + 1}${number.group(2)}';
    } else if (bullet.length > 1 && bullet.endsWith(']')) {
      next = '${bullet.substring(0, bullet.length - 3)}[ ]';
    }
    final inserted = '$indent$next ';
    return TextEditingValue(
      text: text.replaceRange(at, at, inserted),
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }
}
