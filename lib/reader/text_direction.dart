bool? firstStrongIsRtl(String text) {
  for (final rune in text.runes) {
    if (_isRtl(rune)) return true;
    if (_isLtrLetter(rune)) return false;
  }
  return null;
}

bool _isRtl(int c) {
  return (c >= 0x0590 && c <= 0x08FF) ||
      (c >= 0xFB1D && c <= 0xFDFF) ||
      (c >= 0xFE70 && c <= 0xFEFF);
}

bool _isLtrLetter(int c) {
  if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) return true;
  if (c >= 0xC0 && c <= 0x24F) return true;
  if (c >= 0x370 && c <= 0x58F) return true;
  if (c >= 0x900 && c <= 0x1FFF) return true;
  if (c >= 0x2E80 && c <= 0xD7FF) return true;
  return false;
}
