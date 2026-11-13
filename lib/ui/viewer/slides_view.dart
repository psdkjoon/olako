import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/localization/localization.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/viewer/slide_widgets.dart';

class SlidesView extends StatefulWidget {
  const SlidesView({
    required this.deck,
    required this.initialPosition,
    required this.onProgress,
    super.key,
  });

  final SlideDeck deck;
  final double initialPosition;
  final void Function(double position, double progress) onProgress;

  @override
  State<SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends State<SlidesView> {
  final ScrollController _controller = ScrollController();
  int _restoreRuns = 0;
  bool _dragged = false;

  double _fractionNow() {
    if (!_controller.hasClients) return 0;
    final position = _controller.position;
    if (!position.hasContentDimensions) return 0;
    final max = position.maxScrollExtent;
    return max <= 0 ? 0.0 : math.min(1.0, math.max(0.0, position.pixels / max));
  }

  void _report() {
    final value = _fractionNow();
    widget.onProgress(value, value);
  }

  void _restore() {
    if (!mounted || _dragged) return;
    if (!_controller.hasClients || !_controller.position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
      return;
    }
    final position = _controller.position;
    final target = math.min(
      position.maxScrollExtent,
      math.max(0.0, widget.initialPosition * position.maxScrollExtent),
    );
    if ((position.pixels - target).abs() > 1) _controller.jumpTo(target);
    _restoreRuns++;
    if (_restoreRuns < 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialPosition > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    }
  }

  @override
  void dispose() {
    if (_controller.hasClients) _report();
    _controller.dispose();
    super.dispose();
  }

  void _open(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SlidePager(deck: widget.deck, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    final theme = Theme.of(context);
    final slides = deck.slides;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _dragged = true;
        } else if (notification is ScrollEndNotification) {
          _report();
        }
        return false;
      },
      child: SelectionArea(
        child: ListView.builder(
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.xxl,
          ),
          itemCount: slides.length,
          itemBuilder: (context, index) {
            final slide = slides[index];
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          left: AppSpacing.xxs,
                          right: AppSpacing.xxs,
                          bottom: AppSpacing.xxs,
                        ),
                        child: Text(
                          '${index + 1} / ${slides.length}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: slide.title.isEmpty
                            ? 'Slide ${index + 1}'.tr
                            : slide.title,
                        child: GestureDetector(
                          onTap: () => _open(index),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: SlideCanvas(
                                slide: slide,
                                widthPt: deck.widthPt,
                                heightPt: deck.heightPt,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class SlidePager extends StatefulWidget {
  const SlidePager({required this.deck, required this.initialIndex, super.key});

  final SlideDeck deck;
  final int initialIndex;

  @override
  State<SlidePager> createState() => _SlidePagerState();
}

class _SlidePagerState extends State<SlidePager> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  final TransformationController _zoom = TransformationController();
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _changed(int index) {
    _zoom.value = Matrix4.identity();
    setState(() {
      _index = index;
      _zoomed = false;
    });
  }

  void _zoomEnded() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.02;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _showNotes(String notes) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              0,
              AppSpacing.xl,
              AppSpacing.xxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.sm,
              children: [
                Text('Speaker notes', style: theme.textTheme.titleMedium),
                SelectableText(notes, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    final slide = deck.slides[math.min(_index, deck.slides.length - 1)];
    final notes = slide.notes.trim();
    return Scaffold(
      appBar: AppBar(
        title: Text('${_index + 1} / ${deck.slides.length}'),
        actions: [
          if (notes.isNotEmpty)
            IconButton(
              tooltip: 'Speaker notes'.tr,
              icon: const Icon(Icons.sticky_note_2_outlined),
              onPressed: () => _showNotes(notes),
            ),
        ],
      ),
      body: SafeArea(
        child: PageView.builder(
          controller: _pages,
          physics: _zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: deck.slides.length,
          onPageChanged: _changed,
          itemBuilder: (context, index) {
            return SelectionArea(
              child: InteractiveViewer(
                transformationController: index == _index ? _zoom : null,
                minScale: 1,
                maxScale: 5,
                panEnabled: _zoomed,
                onInteractionEnd: (_) => _zoomEnded(),
                child: Center(
                  child: SlideCanvas(
                    slide: deck.slides[index],
                    widthPt: deck.widthPt,
                    heightPt: deck.heightPt,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
