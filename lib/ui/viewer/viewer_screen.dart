import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/core/recent_store.dart';
import 'package:olako/export/export_screen.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/pdf_edit/pdf_edit_screen.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/ui/document_opener.dart';
import 'package:olako/platform/system_service.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/settings/app_settings.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/editor/editor_screen.dart';
import 'package:olako/ui/viewer/document_view.dart';
import 'package:olako/ui/viewer/pdf_view.dart';
import 'package:olako/ui/viewer/slides_view.dart';
import 'package:olako/ui/widgets/kind_info.dart';

String _mimeOf(DocumentKind kind) {
  return switch (kind) {
    DocumentKind.word =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    DocumentKind.slides =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    DocumentKind.markdown => 'text/markdown',
    DocumentKind.pdf => 'application/pdf',
    DocumentKind.text => 'text/plain',
    DocumentKind.table => 'text/csv',
    DocumentKind.sheet =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    DocumentKind.opendoc => 'application/vnd.oasis.opendocument.text',
  };
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    required this.entry,
    required this.recents,
    required this.settings,
    super.key,
  });

  final RecentEntry entry;
  final RecentStore recents;
  final AppSettings settings;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen>
    with SingleTickerProviderStateMixin {
  LoadOutcome? _outcome;
  late bool _asText = widget.settings.slidesAsText;
  bool _switched = false;
  late bool _pages = widget.entry.kind == DocumentKind.pdf;
  late bool _invert = widget.settings.invertPages;
  final PdfPagesController _pagesController = PdfPagesController();
  bool _immersive = false;
  int _revision = 0;
  bool _chrome = true;
  bool _suppress = false;
  bool _tapOk = false;
  int _pointers = 0;
  int _downTime = 0;
  Offset _downAt = Offset.zero;
  double _inset = 0;
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final Animation<double> _barCurve = CurvedAnimation(
    parent: _bar,
    curve: Curves.easeInOutCubic,
  );
  Timer? _fadeTimer;
  Timer? _tapTimer;
  String _pagesNote = '';
  List<DocBlock>? _outline;

  @override
  void initState() {
    super.initState();
    if (!_pages) unawaited(_load());
    if (widget.settings.keepAwake) unawaited(SystemService.keepAwake(true));
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _tapTimer?.cancel();
    _bar.dispose();
    if (_immersive) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    unawaited(SystemService.keepAwake(false));
    _pagesController.dispose();
    super.dispose();
  }

  void _togglePages() {
    setState(() {
      _pages = !_pages;
      _switched = true;
    });
    if (!_pages && _outcome == null) unawaited(_load());
  }

  void _pagesFailed(String reason) {
    if (!mounted) return;
    setState(() {
      _pages = false;
      _pagesNote = reason;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final outcome = await loadDocument(widget.entry.path, widget.entry.kind);
    if (!mounted) return;
    setState(() => _outcome = outcome);
  }

  void _save(double position, double progress) {
    widget.recents.saveProgress(widget.entry.id, position, progress);
  }

  void _armFade() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _immersive) setState(() => _chrome = false);
    });
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers++;
    if (_suppress) {
      _suppress = false;
      _tapOk = false;
      return;
    }
    _tapOk = _pointers == 1;
    _downAt = event.position;
    _downTime = event.timeStamp.inMilliseconds;
    if (_immersive && _chrome) _armFade();
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_tapOk && (event.position - _downAt).distance > 18) _tapOk = false;
  }

  void _pointerUp(PointerUpEvent event) {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    final quick = event.timeStamp.inMilliseconds - _downTime < 350;
    final accepted = _tapOk && quick && _pointers == 0;
    _tapOk = false;
    if (!accepted) return;
    final waiting = _tapTimer;
    if (waiting != null && waiting.isActive) {
      waiting.cancel();
      return;
    }
    _tapTimer = Timer(const Duration(milliseconds: 280), _onTap);
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    _tapOk = false;
  }

  void _onTap() {
    if (!mounted) return;
    if (!_immersive) {
      _setImmersive(true);
    } else if (_chrome) {
      _setImmersive(false);
    } else {
      setState(() => _chrome = true);
      _armFade();
    }
  }

  void _setImmersive(bool value) {
    _fadeTimer?.cancel();
    setState(() {
      _immersive = value;
      _chrome = true;
    });
    if (value) {
      _armFade();
      unawaited(_bar.reverse());
    } else {
      unawaited(_bar.forward());
    }
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  void _showDetails() {
    final entry = widget.entry;
    final pages = _pagesController.count;
    final rows = <(String, String)>[
      ('Name', entry.name),
      ('Type', KindInfo.label(entry.kind)),
      ('Size', KindInfo.size(entry.size)),
      if (_pages && pages > 0) ('Pages', '$pages'.tr),
      ('Read', '${(entry.progress * 100).round()}%'.tr),
      ('Location', entry.owned ? 'Kept by this app'.tr : entry.path),
    ];
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          final theme = Theme.of(sheetContext);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                0,
                AppSpacing.xl,
                AppSpacing.xl,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.md,
                children: [
                  Text('Details', style: theme.textTheme.titleMedium),
                  for (final row in rows)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.$1,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        SelectableText(
                          row.$2,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _edit() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: DocumentOpener.editorRoute),
        builder: (_) => EditorScreen(
          entry: widget.entry,
          recents: widget.recents,
          settings: widget.settings,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _outcome = null);
    unawaited(_load());
  }

  void _convert() {
    final doc = _outcome?.document;
    if (doc is! TextDocument) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          blocks: doc.blocks,
          name: widget.entry.name,
          settings: widget.settings,
          baseDir: File(widget.entry.path).parent.path,
        ),
      ),
    );
  }

  Future<void> _editPages() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            PdfEditScreen(entry: widget.entry, recents: widget.recents),
      ),
    );
    if (!mounted || saved != true) return;
    setState(() {
      _revision++;
      _outcome = null;
    });
    if (!_pages) unawaited(_load());
  }

  Future<void> _share() async {
    final done = await DocumentService.share(
      widget.entry.path,
      _mimeOf(widget.entry.kind),
    );
    if (done || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Couldn't share this document")),
    );
  }

  Future<void> _remove() async {
    final navigator = Navigator.of(context);
    await widget.recents.remove(widget.entry.id);
    navigator.pop();
  }

  void _showSizeSheet() {
    final settings = widget.settings;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            final theme = Theme.of(context);
            final scale = settings.readerScale;
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                0,
                AppSpacing.xl,
                AppSpacing.xl,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Text size',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      Text('$scale%', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Smaller'.tr,
                        icon: const Icon(Icons.text_decrease_rounded),
                        onPressed: scale <= AppSettings.minReaderScale
                            ? null
                            : () => settings.readerScale = scale - 10,
                      ),
                      Expanded(
                        child: Slider(
                          min: AppSettings.minReaderScale.toDouble(),
                          max: AppSettings.maxReaderScale.toDouble(),
                          divisions:
                              (AppSettings.maxReaderScale -
                                  AppSettings.minReaderScale) ~/
                              10,
                          value: scale.toDouble(),
                          onChanged: (value) =>
                              settings.readerScale = value.round(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Larger'.tr,
                        icon: const Icon(Icons.text_increase_rounded),
                        onPressed: scale >= AppSettings.maxReaderScale
                            ? null
                            : () => settings.readerScale = scale + 10,
                      ),
                    ],
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: scale == 100
                          ? null
                          : () => settings.readerScale = 100,
                      child: const Text('Reset'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  List<DocBlock> _outlineOf(SlideDeck deck) {
    final cached = _outline;
    if (cached != null) return cached;
    final blocks = <DocBlock>[];
    for (var i = 0; i < deck.slides.length; i++) {
      final slide = deck.slides[i];
      if (i > 0) blocks.add(const RuleBlock());
      blocks.add(
        ParagraphBlock(
          inlines: <Inline>[TextRun('Slide ${i + 1}'.tr)],
          heading: 6,
        ),
      );
      blocks.addAll(slide.outline);
      final notes = slide.notes.trim();
      if (notes.isNotEmpty) {
        blocks.add(
          QuoteBlock(
            children: <DocBlock>[
              ParagraphBlock(
                inlines: <Inline>[
                  TextRun('Speaker notes'.tr, const RunStyle(bold: true)),
                ],
              ),
              ParagraphBlock(inlines: <Inline>[TextRun(notes)]),
            ],
          ),
        );
      }
    }
    return _outline = blocks;
  }

  Widget _withNotice(String detail, Widget child, {String? message}) {
    if (detail.isEmpty) return child;
    return Column(
      children: [
        _RescueBanner(detail: detail, message: message),
        Expanded(child: child),
      ],
    );
  }

  Widget _body(LoadOutcome? outcome) {
    if (_pages) {
      return PdfPagesView(
        key: ValueKey<String>('pages$_revision'),
        path: widget.entry.path,
        initialPosition: _switched ? 0 : widget.entry.position,
        invert: _invert,
        controller: _pagesController,
        onProgress: _save,
        onFailed: _pagesFailed,
        chipVisible: !_immersive || _chrome,
        onChipTouch: () => _suppress = true,
      );
    }
    if (outcome == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final problem = outcome.problem;
    if (problem != null) {
      return _ProblemView(
        problem: problem,
        detail: _pagesNote.isEmpty
            ? outcome.detail
            : '${outcome.detail}\nPage view: $_pagesNote',
        onShare: _share,
        onRemove: _remove,
      );
    }
    final doc = outcome.document;
    if (doc is TextDocument) {
      if (doc.blocks.isEmpty) {
        return const _Notice(
          icon: Icons.insert_drive_file_outlined,
          message: 'This document is empty.',
        );
      }
      return _withNotice(
        _pagesNote.isEmpty ? outcome.detail : 'Page view: $_pagesNote',
        message: _pagesNote.isEmpty
            ? null
            : 'The page view could not be opened, so the text is shown instead.',
        ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => DocumentView(
            blocks: doc.blocks,
            baseSizePt: doc.baseSizePt,
            readerScale: widget.settings.readerScale,
            initialPosition: _switched ? 0 : widget.entry.position,
            onProgress: _save,
            markdown: doc.markdown,
          ),
        ),
      );
    }
    if (doc is SlideDeck) {
      if (doc.slides.isEmpty) {
        return const _Notice(
          icon: Icons.slideshow_outlined,
          message: 'This presentation has no slides.',
        );
      }
      if (_asText) {
        return ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => DocumentView(
            key: const ValueKey<String>('outline'),
            blocks: _outlineOf(doc),
            baseSizePt: 18,
            readerScale: widget.settings.readerScale,
            initialPosition: _switched ? 0 : widget.entry.position,
            onProgress: _save,
          ),
        );
      }
      return _withNotice(
        outcome.detail,
        SlidesView(
          key: const ValueKey<String>('slides'),
          deck: doc,
          initialPosition: _switched ? 0 : widget.entry.position,
          onProgress: _save,
        ),
      );
    }
    return const _Notice(
      icon: Icons.error_outline_rounded,
      message: 'This kind of file cannot be opened.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final doc = outcome?.document;
    final textual =
        !_pages && (doc is TextDocument || (doc is SlideDeck && _asText));
    final media = MediaQuery.of(context);
    if (!_immersive) _inset = media.padding.top;
    final appBar = AppBar(
      title: w.Text(
        widget.entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (widget.entry.kind == DocumentKind.pdf)
          IconButton(
            tooltip: (_pages ? 'Show as text' : 'Show as pages').tr,
            icon: Icon(
              _pages
                  ? Icons.format_align_left_rounded
                  : Icons.picture_as_pdf_outlined,
            ),
            onPressed: _togglePages,
          ),
        if (_pages)
          IconButton(
            tooltip: 'Invert colors'.tr,
            icon: const Icon(Icons.invert_colors_rounded),
            onPressed: () => setState(() {
              _invert = !_invert;
              widget.settings.invertPages = _invert;
            }),
          ),
        if (doc is SlideDeck)
          IconButton(
            tooltip: (_asText ? 'Show as slides' : 'Show as text').tr,
            icon: Icon(
              _asText
                  ? Icons.slideshow_rounded
                  : Icons.format_align_left_rounded,
            ),
            onPressed: () => setState(() {
              _asText = !_asText;
              _switched = true;
            }),
          ),
        if (textual)
          IconButton(
            tooltip: 'Text size'.tr,
            icon: const Icon(Icons.text_fields_rounded),
            onPressed: _showSizeSheet,
          ),
        if (EditorScreen.canEdit(widget.entry.kind))
          IconButton(
            tooltip: 'Edit'.tr,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => unawaited(_edit()),
          ),
        IconButton(
          tooltip: 'Share'.tr,
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: _share,
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'full') {
              _setImmersive(true);
            } else if (value == 'pdf') {
              _convert();
            } else if (value == 'pages') {
              unawaited(_editPages());
            } else {
              _showDetails();
            }
          },
          itemBuilder: (context) => [
            if (widget.entry.kind == DocumentKind.pdf)
              const PopupMenuItem(value: 'pages', child: Text('Edit pages')),
            if (doc is TextDocument)
              const PopupMenuItem(value: 'pdf', child: Text('Convert to PDF')),
            const PopupMenuItem(value: 'full', child: Text('Full screen')),
            const PopupMenuItem(value: 'details', child: Text('Details')),
          ],
        ),
      ],
    );
    return PopScope(
      canPop: !_immersive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setImmersive(false);
      },
      child: Scaffold(
        body: Column(
          children: [
            AnimatedBuilder(
              animation: _barCurve,
              builder: (context, _) => ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: _barCurve.value,
                  child: SizedBox(
                    height: kToolbarHeight + _inset,
                    child: MediaQuery(
                      data: media.copyWith(
                        padding: media.padding.copyWith(top: _inset),
                      ),
                      child: appBar,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _pointerDown,
                onPointerMove: _pointerMove,
                onPointerUp: _pointerUp,
                onPointerCancel: _pointerCancel,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SafeArea(top: false, child: _body(outcome)),
                    ),
                    PositionedDirectional(
                      top: AppSpacing.md,
                      end: AppSpacing.md,
                      child: SafeArea(
                        child: AnimatedOpacity(
                          opacity: _immersive && _chrome ? 1 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: IgnorePointer(
                            ignoring: !(_immersive && _chrome),
                            child: Listener(
                              onPointerDown: (_) => _suppress = true,
                              child: IconButton.filledTonal(
                                tooltip: 'Exit full screen'.tr,
                                icon: const Icon(Icons.fullscreen_exit_rounded),
                                onPressed: () => _setImmersive(false),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.md,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _RescueBanner extends StatelessWidget {
  const _RescueBanner({required this.detail, this.message});

  final String detail;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.sm,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message ??
                        'Some formatting could not be read, so the text is shown in a simple form.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  if (detail != 'rescued')
                    SelectableText(
                      detail,
                      maxLines: 4,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemView extends StatelessWidget {
  const _ProblemView({
    required this.problem,
    required this.detail,
    required this.onShare,
    required this.onRemove,
  });

  final DocumentProblem problem;
  final String detail;
  final VoidCallback onShare;
  final VoidCallback onRemove;

  static String _message(DocumentProblem problem) {
    return switch (problem) {
      DocumentProblem.legacyFormat =>
        'This is an old Word or PowerPoint file (.doc or .ppt). Open it in an office app, save it as .docx or .pptx, then open it here.',
      DocumentProblem.encrypted =>
        "This file is locked with a password, so it can't be opened here.",
      DocumentProblem.damaged =>
        "This file looks damaged, so it can't be opened.",
      DocumentProblem.unsupported => 'This kind of file cannot be opened.',
      DocumentProblem.tooLarge => 'This file is too big to open.',
      DocumentProblem.noText =>
        'This PDF has no text to show. It may be made of scanned pictures.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.md,
            children: [
              Icon(
                problem == DocumentProblem.encrypted
                    ? Icons.lock_outline_rounded
                    : Icons.error_outline_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              Text(
                _message(problem),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (detail.isNotEmpty)
                SelectableText(
                  detail,
                  textAlign: TextAlign.start,
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onShare,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share'),
                  ),
                  TextButton(
                    onPressed: onRemove,
                    child: const Text('Remove from the list'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
