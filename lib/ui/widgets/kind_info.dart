import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/localization/localization.dart';
import 'package:olako/reader/document_loader.dart';

abstract class KindInfo {
  static IconData icon(DocumentKind kind) {
    return switch (kind) {
      DocumentKind.word => Icons.description_outlined,
      DocumentKind.slides => Icons.slideshow_outlined,
      DocumentKind.markdown => Icons.article_outlined,
      DocumentKind.pdf => Icons.picture_as_pdf_outlined,
      DocumentKind.text => Icons.notes_rounded,
      DocumentKind.table => Icons.table_chart_outlined,
      DocumentKind.sheet => Icons.grid_on_outlined,
      DocumentKind.opendoc => Icons.description_outlined,
    };
  }

  static String label(DocumentKind kind) {
    final text = switch (kind) {
      DocumentKind.word => 'Word document',
      DocumentKind.slides => 'Presentation',
      DocumentKind.markdown => 'Markdown',
      DocumentKind.pdf => 'PDF document',
      DocumentKind.text => 'Text file',
      DocumentKind.table => 'Table file',
      DocumentKind.sheet => 'Spreadsheet',
      DocumentKind.opendoc => 'OpenDocument text',
    };
    return text.tr;
  }

  static String size(int bytes) {
    if (bytes < 1024) return '$bytes B'.tr;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB'.tr;
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'.tr;
  }

  static String when(int millis) {
    final then = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(then.year, then.month, then.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'Today'.tr;
    if (days == 1) return 'Yesterday'.tr;
    if (days < 7) return '$days days ago'.tr;
    final month = then.month.toString().padLeft(2, '0');
    final date = then.day.toString().padLeft(2, '0');
    return '${then.year}-$month-$date'.tr;
  }
}
