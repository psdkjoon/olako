import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/localization/localization.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/ui/viewer/doc_style.dart';

TextAlign textAlignOf(DocAlign align) {
  return switch (align) {
    DocAlign.start => TextAlign.start,
    DocAlign.center => TextAlign.center,
    DocAlign.end => TextAlign.end,
    DocAlign.justify => TextAlign.justify,
  };
}

class InlineText extends StatefulWidget {
  const InlineText({
    required this.inlines,
    required this.base,
    required this.context,
    required this.rtl,
    this.align = DocAlign.start,
    super.key,
  });

  final List<Inline> inlines;

  final TextStyle base;
  final TextContext context;
  final bool rtl;
  final DocAlign align;

  @override
  State<InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<InlineText> {
  final List<TapGestureRecognizer> _taps = <TapGestureRecognizer>[];

  void _releaseTaps() {
    for (final tap in _taps) {
      tap.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _releaseTaps();
    super.dispose();
  }

  TextStyle _styleOf(RunStyle run) {
    final ctx = widget.context;
    final baseSize = widget.base.fontSize ?? 16;
    var size = baseSize;
    final pt = run.sizePt;
    if (pt != null && ctx.pxPerPt > 0) {
      size = math.min(math.max(pt * ctx.pxPerPt, baseSize * 0.5), baseSize * 4);
    }
    if (run.code) size *= 0.92;
    if (run.superscript || run.subscript) size *= 0.72;

    final background = run.background == null ? null : Color(run.background!);
    final under = background == null
        ? ctx.surface
        : Color.alphaBlend(background, ctx.surface);
    Color color;
    if (run.link != null) {
      color = readableOn(ctx.link, under, inkOn(under));
    } else if (run.color != null) {
      color = readableOn(Color(run.color!), under, inkOn(under));
    } else if (background != null) {
      color = inkOn(under);
    } else {
      color = widget.base.color ?? ctx.ink;
    }

    final decorations = <TextDecoration>[
      if (run.underline || run.link != null) TextDecoration.underline,
      if (run.strike) TextDecoration.lineThrough,
    ];

    final heavy = run.bold || (widget.base.fontWeight?.value ?? 400) >= 600;
    return TextStyle(
      fontSize: size,
      color: color,
      fontWeight: heavy ? FontWeight.w700 : null,
      fontVariations: <FontVariation>[FontVariation.weight(heavy ? 700 : 400)],
      fontStyle: run.italic ? FontStyle.italic : null,
      fontFamily: run.code ? 'monospace' : null,
      backgroundColor: run.code && background == null
          ? ctx.codeBackground
          : background,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      decorationColor: color,
    );
  }

  InlineSpan _span(Inline inline) {
    switch (inline) {
      case LineBreakInline():
        return const TextSpan(text: '\n');
      case final ImageInline image:
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InlineImage(image: image, context: widget.context),
        );
      case final TextRun run:
        final style = _styleOf(run.style);
        final link = run.style.link;
        if (run.style.superscript || run.style.subscript) {
          final size = style.fontSize ?? 12;
          final lift = run.style.superscript ? -size * 0.45 : size * 0.2;
          return WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: Offset(0, lift),
              child: w.Text(run.text, style: style),
            ),
          );
        }
        TapGestureRecognizer? tap;
        final open = widget.context.onLink;
        if (link != null && open != null) {
          tap = TapGestureRecognizer()..onTap = () => open(link);
          _taps.add(tap);
        }
        return TextSpan(text: run.text, style: style, recognizer: tap);
    }
  }

  @override
  Widget build(BuildContext context) {
    _releaseTaps();
    final spans = <InlineSpan>[
      for (final inline in widget.inlines) _span(inline),
    ];
    return w.Text.rich(
      TextSpan(style: widget.base, children: spans),
      textAlign: textAlignOf(widget.align),
      textDirection: widget.rtl ? TextDirection.rtl : TextDirection.ltr,
      textScaler: widget.context.textScaler,
    );
  }
}

class _InlineImage extends StatelessWidget {
  const _InlineImage({required this.image, required this.context});

  final ImageInline image;
  final TextContext context;

  @override
  Widget build(BuildContext buildContext) {
    final scheme = Theme.of(buildContext).colorScheme;
    final bytes = image.bytes;
    if (bytes == null) {
      return _placeholder(scheme, remote: true);
    }
    final maxWidth = context.imageMaxWidth;
    double? width;
    double? height;
    final wPt = image.widthPt;
    final hPt = image.heightPt;
    if (wPt != null && hPt != null && wPt > 0 && hPt > 0) {
      width = math.min(wPt * context.pxPerPt, maxWidth);
      height = width * hPt / wPt;
    }
    final wanted = math.min(width ?? maxWidth, maxWidth) * context.pixelRatio;
    final decodeWidth = math.min(2400, math.max(64, wanted.round()));
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Image.memory(
        bytes,
        width: width,
        height: height,
        fit: BoxFit.contain,
        cacheWidth: decodeWidth,
        gaplessPlayback: true,
        semanticLabel: image.alt.isEmpty ? null : image.alt,
        errorBuilder: (_, _, _) => _placeholder(scheme, remote: false),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme, {required bool remote}) {
    final label = image.alt.isEmpty ? 'Picture'.tr : image.alt;
    final address = image.source;
    final open = context.onLink;
    final tappable = remote && open != null && address.startsWith('http');
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: w.Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
    if (!tappable) return chip;
    return GestureDetector(onTap: () => open(address), child: chip);
  }
}
