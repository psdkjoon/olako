import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/core/recent_store.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/pdf_edit/models.dart';
import 'package:olako/pdf_edit/overlay_paint.dart';
import 'package:olako/pdf_edit/page_editor.dart';
import 'package:olako/pdf_edit/page_images.dart';
import 'package:olako/pdf_edit/tools.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/document_opener.dart';

class PdfEditScreen extends StatefulWidget {
  const PdfEditScreen({required this.entry, required this.recents, super.key});

  final RecentEntry entry;
  final RecentStore recents;

  @override
  State<PdfEditScreen> createState() => _PdfEditScreenState();
}

class _PdfEditScreenState extends State<PdfEditScreen> {
  final PageImages _images = PageImages();
  final PictureStore _store = PictureStore();
  final List<PdfSource> _sources = <PdfSource>[];
  final List<List<PageItem>> _undo = <List<PageItem>>[];
  final List<List<PageItem>> _redo = <List<PageItem>>[];
  final Set<String> _selected = <String>{};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _gridKey = GlobalKey();

  List<PageItem> _pages = <PageItem>[];
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;
  String _failure = '';
  String _title = '';
  String _author = '';
  int _serial = 0;
  Timer? _scrollTimer;
  double _scrollSpeed = 0;

  String get _stem {
    final stem = widget.entry.name.replaceFirst(RegExp(r'\.[^./\\]+$'), '');
    return stem.isEmpty ? 'document' : stem;
  }

  String _nextId() => 'p${_serial++}';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _scroll.dispose();
    _images.dispose();
    _store.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final source = await _images.load(widget.entry.path, widget.entry.name);
    if (!mounted) return;
    if (source == null) {
      setState(() {
        _loading = false;
        _failure = "This PDF is protected or damaged, so it can't be edited";
      });
      return;
    }
    _sources.add(source);
    setState(() {
      _pages = _pagesOf(source, 0);
      _loading = false;
    });
  }

  List<PageItem> _pagesOf(PdfSource source, int index) {
    return <PageItem>[
      for (var i = 0; i < source.sizes.length; i++)
        PageItem(id: _nextId(), source: index, index: i, size: source.sizes[i]),
    ];
  }

  void _say(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _apply(List<PageItem> next) {
    _undo.add(_pages);
    if (_undo.length > 80) _undo.removeAt(0);
    _redo.clear();
    final ids = <String>{for (final p in next) p.id};
    setState(() {
      _pages = next;
      _selected.retainWhere(ids.contains);
      _changed = true;
    });
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    _redo.add(_pages);
    final ids = <String>{};
    setState(() {
      _pages = _undo.removeLast();
      for (final p in _pages) {
        ids.add(p.id);
      }
      _selected.retainWhere(ids.contains);
      _changed = true;
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _undo.add(_pages);
    final ids = <String>{};
    setState(() {
      _pages = _redo.removeLast();
      for (final p in _pages) {
        ids.add(p.id);
      }
      _selected.retainWhere(ids.contains);
      _changed = true;
    });
  }

  List<PageItem> get _chosen => <PageItem>[
    for (final p in _pages)
      if (_selected.contains(p.id)) p,
  ];

  int get _insertAt {
    var at = _pages.length;
    for (var i = 0; i < _pages.length; i++) {
      if (_selected.contains(_pages[i].id)) at = i + 1;
    }
    return at;
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _rotate(int dir) {
    _apply(<PageItem>[
      for (final p in _pages)
        if (_selected.contains(p.id))
          p.copyWith(turns: (p.turns + dir + 4) % 4)
        else
          p,
    ]);
  }

  void _delete() {
    final rest = <PageItem>[
      for (final p in _pages)
        if (!_selected.contains(p.id)) p,
    ];
    if (rest.isEmpty) {
      _say('A document needs at least one page');
      return;
    }
    _apply(rest);
  }

  void _duplicate() {
    final next = <PageItem>[];
    for (final p in _pages) {
      next.add(p);
      if (_selected.contains(p.id)) {
        next.add(p.copyWith(id: _nextId(), overlays: cloneAll(p.overlays)));
      }
    }
    _apply(next);
  }

  void _shift(int dir) {
    final next = List<PageItem>.of(_pages);
    if (dir < 0) {
      for (var i = 1; i < next.length; i++) {
        if (_selected.contains(next[i].id) &&
            !_selected.contains(next[i - 1].id)) {
          final t = next[i];
          next[i] = next[i - 1];
          next[i - 1] = t;
        }
      }
    } else {
      for (var i = next.length - 2; i >= 0; i--) {
        if (_selected.contains(next[i].id) &&
            !_selected.contains(next[i + 1].id)) {
          final t = next[i];
          next[i] = next[i + 1];
          next[i + 1] = t;
        }
      }
    }
    _apply(next);
  }

  void _sendTo(bool start) {
    final moving = _chosen;
    final rest = <PageItem>[
      for (final p in _pages)
        if (!_selected.contains(p.id)) p,
    ];
    _apply(
      start ? <PageItem>[...moving, ...rest] : <PageItem>[...rest, ...moving],
    );
  }

  void _drop(String dragged, String targetId) {
    final ids = _selected.contains(dragged) && _selected.length > 1
        ? Set<String>.of(_selected)
        : <String>{dragged};
    if (ids.contains(targetId)) return;
    final moving = <PageItem>[
      for (final p in _pages)
        if (ids.contains(p.id)) p,
    ];
    final rest = <PageItem>[
      for (final p in _pages)
        if (!ids.contains(p.id)) p,
    ];
    final targetOld = _pages.indexWhere((p) => p.id == targetId);
    final firstOld = _pages.indexWhere((p) => ids.contains(p.id));
    final t = rest.indexWhere((p) => p.id == targetId);
    if (t < 0 || targetOld < 0) return;
    rest.insertAll(firstOld < targetOld ? t + 1 : t, moving);
    _apply(rest);
  }

  void _reverse() {
    _apply(_pages.reversed.toList());
  }

  void _selectWhere(bool Function(int index) test) {
    setState(() {
      _selected.clear();
      for (var i = 0; i < _pages.length; i++) {
        if (test(i)) _selected.add(_pages[i].id);
      }
    });
  }

  Set<String>? get _scope =>
      _selected.isEmpty ? null : Set<String>.of(_selected);

  Future<void> _openEditor(PageItem page) async {
    final source = page.blank ? null : _sources[page.source];
    final result = await Navigator.of(context).push<List<Annotation>>(
      MaterialPageRoute<List<Annotation>>(
        builder: (_) => PageEditorScreen(
          page: page,
          source: source,
          images: _images,
          store: _store,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.isEmpty && page.overlays.isEmpty) return;
    _apply(<PageItem>[
      for (final p in _pages)
        if (p.id == page.id) p.copyWith(overlays: result) else p,
    ]);
  }

  Future<void> _addPdfs(List<String> paths) async {
    final added = <PageItem>[];
    for (final path in paths) {
      final name = path.split('/').last;
      final source = await _images.load(path, name);
      if (!mounted) return;
      if (source == null) {
        _say("Couldn't add $name");
        continue;
      }
      _sources.add(source);
      added.addAll(_pagesOf(source, _sources.length - 1));
    }
    if (added.isEmpty) return;
    final next = List<PageItem>.of(_pages)..insertAll(_insertAt, added);
    _apply(next);
  }

  Future<void> _pickPdfs() async {
    final paths = await DocumentService.pickMany(<String>['application/pdf']);
    if (paths.isEmpty || !mounted) return;
    await _addPdfs(paths);
  }

  Future<void> _pickFromLibrary() async {
    final items = <RecentEntry>[
      for (final e in widget.recents.entries)
        if (e.kind == DocumentKind.pdf && File(e.path).existsSync()) e,
    ];
    if (items.isEmpty) {
      _say('No PDF documents in your library yet');
      return;
    }
    final chosen = await showModalBottomSheet<RecentEntry>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in items)
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(e),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _addPdfs(<String>[chosen.path]);
  }

  Future<void> _pickImages() async {
    final paths = await DocumentService.pickMany(<String>['image/*']);
    if (paths.isEmpty || !mounted) return;
    final added = <PageItem>[];
    for (final path in paths) {
      final size = await imageSize(path);
      if (!mounted) return;
      if (size == null) {
        _say("Couldn't open this image");
        continue;
      }
      const width = 595.0;
      final height = (width * size.height / size.width)
          .clamp(120.0, 2400.0)
          .toDouble();
      added.add(
        PageItem(
          id: _nextId(),
          source: -1,
          index: 0,
          size: Size(width, height),
          overlays: <Annotation>[
            PictureOverlay(
              rect: Rect.fromLTWH(0, 0, width, height),
              path: path,
            ),
          ],
        ),
      );
    }
    if (added.isEmpty) return;
    final next = List<PageItem>.of(_pages)..insertAll(_insertAt, added);
    _apply(next);
  }

  void _addBlank() {
    Size size = const Size(595, 842);
    final at = _insertAt;
    final reference = _pages.isEmpty
        ? null
        : _pages[(at - 1).clamp(0, _pages.length - 1).toInt()];
    if (reference != null) size = reference.visible.size;
    final next = List<PageItem>.of(_pages)
      ..insert(at, PageItem(id: _nextId(), source: -1, index: 0, size: size));
    _apply(next);
  }

  Future<void> _numbers() async {
    final setup = await askNumbers(
      context,
      hasSelection: _selected.isNotEmpty,
      total: _pages.length,
    );
    if (setup == null || !mounted) return;
    setState(() => _busy = true);
    final next = await applyNumbers(
      _pages,
      setup.selectedOnly ? _scope : null,
      setup,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _apply(next);
  }

  Future<void> _watermark() async {
    final setup = await askWatermark(
      context,
      hasSelection: _selected.isNotEmpty,
    );
    if (setup == null || !mounted) return;
    setState(() => _busy = true);
    final next = await applyWatermark(
      _pages,
      setup.selectedOnly ? _scope : null,
      setup,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _apply(next);
  }

  Future<void> _crop() async {
    final setup = await askCrop(context, hasSelection: _selected.isNotEmpty);
    if (setup == null || !mounted) return;
    _apply(applyCrop(_pages, setup.selectedOnly ? _scope : null, setup.insets));
  }

  Future<void> _info() async {
    final answer = await askInfo(context, _title, _author);
    if (answer == null) return;
    setState(() {
      _title = answer.$1;
      _author = answer.$2;
      _changed = true;
    });
  }

  Future<PdfEditResult?> _build(List<PageItem> pages, String name) async {
    setState(() => _busy = true);
    final results = await DocumentService.editPdf(<Map<String, Object?>>[
      buildJob(
        name: name,
        pages: pages,
        sources: _sources,
        title: _title,
        author: _author,
      ),
    ]);
    if (!mounted) return null;
    setState(() => _busy = false);
    final result = results.first;
    if (!result.ok) {
      _say(
        result.error == 'encrypted'
            ? "This PDF is protected and can't be edited"
            : "Couldn't save the PDF",
      );
      return null;
    }
    return result;
  }

  Future<String?> _chooseSave({required bool overwrite}) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (overwrite)
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: const Text('Save changes'),
                subtitle: const Text('Replaces this document'),
                onTap: () => Navigator.of(sheetContext).pop('replace'),
              ),
            ListTile(
              leading: const Icon(Icons.library_add_outlined),
              title: const Text('Save as a new document'),
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share'),
              onTap: () => Navigator.of(sheetContext).pop('share'),
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Save to Downloads'),
              onTap: () => Navigator.of(sheetContext).pop('downloads'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save({List<PageItem>? only, bool overwrite = true}) async {
    final pages = only ?? _pages;
    final choice = await _chooseSave(overwrite: overwrite && only == null);
    if (choice == null || !mounted) return;
    final name = choice == 'replace'
        ? widget.entry.name
        : only == null
        ? '$_stem-edited.pdf'
        : '$_stem-extract.pdf';
    final result = await _build(pages, name);
    if (result == null || !mounted) return;
    switch (choice) {
      case 'replace':
        await _replace(result);
      case 'copy':
        final navigator = Navigator.of(context);
        _changed = false;
        navigator.pop(false);
        unawaited(DocumentOpener.keep(result.path, result.name));
      case 'share':
        final done = await DocumentService.share(
          result.path,
          'application/pdf',
        );
        if (!done && mounted) _say("Couldn't share this document");
      case 'downloads':
        final done = await DocumentService.saveDownload(
          result.path,
          result.name,
        );
        if (mounted)
          _say(done ? 'Saved to Downloads' : "Couldn't save the file");
    }
  }

  Future<void> _replace(PdfEditResult result) async {
    final target = File(widget.entry.path);
    final temp = File('${target.path}.new');
    try {
      await File(result.path).copy(temp.path);
      await temp.rename(target.path);
      widget.recents.updateSize(widget.entry.id, await target.length());
      _changed = false;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object {
      if (mounted) _say("Couldn't save the file");
    }
  }

  Future<void> _extract() async {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    await _save(only: chosen, overwrite: false);
  }

  Future<void> _split() async {
    final plan = await askSplit(context, _pages.length);
    if (plan == null || !mounted) return;
    final jobs = <Map<String, Object?>>[];
    for (var i = 0; i < plan.length; i++) {
      final group = plan[i];
      final label = group.length == 1
          ? '${group.first + 1}'
          : '${group.first + 1}-${group.last + 1}';
      jobs.add(
        buildJob(
          name: '$_stem-$label.pdf',
          pages: <PageItem>[for (final index in group) _pages[index]],
          sources: _sources,
          title: _title,
          author: _author,
        ),
      );
    }
    setState(() => _busy = true);
    final results = await DocumentService.editPdf(jobs);
    if (!mounted) return;
    setState(() => _busy = false);
    final good = <PdfEditResult>[
      for (final r in results)
        if (r.ok) r,
    ];
    if (good.isEmpty) {
      _say("Couldn't save the PDF");
      return;
    }
    await _showFiles(good);
  }

  Future<void> _showFiles(List<PdfEditResult> files) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in files)
                      ListTile(
                        leading: const Icon(Icons.picture_as_pdf_outlined),
                        title: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${f.pages} pages'),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Save all'),
                        onPressed: () async {
                          var saved = 0;
                          for (final f in files) {
                            if (await DocumentService.saveDownload(
                              f.path,
                              f.name,
                            ))
                              saved++;
                          }
                          if (!sheetContext.mounted) return;
                          Navigator.of(sheetContext).pop();
                          if (mounted) {
                            _say(
                              saved > 0
                                  ? 'Saved to Downloads'
                                  : "Couldn't save the file",
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('Share all'),
                        onPressed: () => unawaited(
                          DocumentService.shareMany(<String>[
                            for (final f in files) f.path,
                          ], 'application/pdf'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leave() async {
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
      return;
    }
    final navigator = Navigator.of(context);
    if (!_changed) {
      navigator.pop(false);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text(
          "This document has changes that haven't been saved.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('stay'),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text("Don't save"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'discard') {
      navigator.pop(false);
    } else if (choice == 'save') {
      await _save();
    }
  }

  void _dragUpdate(DragUpdateDetails details) {
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = details.globalPosition.dy;
    const zone = 80.0;
    double speed = 0;
    if (y < top + zone) {
      speed = -((top + zone - y) / zone).clamp(0.0, 1.0).toDouble() * 18;
    } else if (y > bottom - zone) {
      speed = ((y - (bottom - zone)) / zone).clamp(0.0, 1.0).toDouble() * 18;
    }
    _scrollSpeed = speed;
    if (speed == 0) {
      _scrollTimer?.cancel();
      _scrollTimer = null;
      return;
    }
    _scrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      final next = (position.pixels + _scrollSpeed)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      _scroll.jumpTo(next);
    });
  }

  void _stopScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _scrollSpeed = 0;
  }

  Widget _tile(int i) {
    final page = _pages[i];
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected.contains(page.id);
    final source = page.blank ? null : _sources[page.source];
    final card = Container(
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(
          color: selected ? scheme.primary : Colors.transparent,
          width: 2.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _Thumb(
                page: page,
                source: source,
                images: _images,
                store: _store,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L10n.digits('${i + 1}'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
    final body = Stack(
      children: [
        Positioned.fill(child: card),
        PositionedDirectional(
          top: 4,
          start: 4,
          child: InkResponse(
            radius: 22,
            onTap: () => _toggle(page.id),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.primary
                    : scheme.surface.withValues(alpha: 0.85),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outline,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary)
                  : null,
            ),
          ),
        ),
        PositionedDirectional(
          bottom: 6,
          end: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (page.cropped)
                Icon(
                  Icons.crop_rounded,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
              if (page.overlays.isNotEmpty)
                Icon(Icons.edit_rounded, size: 15, color: scheme.primary),
            ],
          ),
        ),
      ],
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != page.id,
      onAcceptWithDetails: (d) => _drop(d.data, page.id),
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        return LongPressDraggable<String>(
          data: page.id,
          onDragUpdate: _dragUpdate,
          onDragEnd: (_) => _stopScroll(),
          onDraggableCanceled: (_, __) => _stopScroll(),
          feedback: SizedBox(
            width: 104,
            child: Material(
              elevation: 8,
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.tile),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: _Thumb(
                  page: page,
                  source: source,
                  images: _images,
                  store: _store,
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: body),
          child: GestureDetector(
            onTap: () {
              if (_selected.isNotEmpty) {
                _toggle(page.id);
              } else {
                unawaited(_openEditor(page));
              }
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.tile),
                boxShadow: hovering
                    ? <BoxShadow>[
                        BoxShadow(
                          color: scheme.primary,
                          blurRadius: 0,
                          spreadRadius: 3,
                        ),
                      ]
                    : null,
              ),
              child: body,
            ),
          ),
        );
      },
    );
  }

  Widget _grid() {
    return GridView.builder(
      key: _gridKey,
      controller: _scroll,
      padding: const EdgeInsets.all(AppSpacing.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 0.66,
      ),
      itemCount: _pages.length,
      itemBuilder: (context, i) => _tile(i),
    );
  }

  PreferredSizeWidget _appBar() {
    final scheme = Theme.of(context).colorScheme;
    if (_selected.isNotEmpty) {
      return AppBar(
        backgroundColor: scheme.primaryContainer,
        leading: IconButton(
          tooltip: 'Clear selection'.tr,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => setState(_selected.clear),
        ),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Select all'.tr,
            icon: const Icon(Icons.select_all_rounded),
            onPressed: () => _selectWhere((_) => true),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'start':
                  _sendTo(true);
                case 'end':
                  _sendTo(false);
                case 'odd':
                  _selectWhere((i) => i.isEven);
                case 'even':
                  _selectWhere((i) => i.isOdd);
                case 'numbers':
                  unawaited(_numbers());
                case 'watermark':
                  unawaited(_watermark());
                case 'crop':
                  unawaited(_crop());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'start', child: Text('Move to start')),
              PopupMenuItem(value: 'end', child: Text('Move to end')),
              PopupMenuItem(value: 'odd', child: Text('Select odd pages')),
              PopupMenuItem(value: 'even', child: Text('Select even pages')),
              PopupMenuItem(value: 'numbers', child: Text('Page numbers')),
              PopupMenuItem(value: 'watermark', child: Text('Watermark')),
              PopupMenuItem(value: 'crop', child: Text('Crop pages')),
            ],
          ),
        ],
      );
    }
    return AppBar(
      leading: IconButton(
        tooltip: 'Back'.tr,
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => unawaited(_leave()),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${_pages.length} pages',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Undo'.tr,
          icon: const Icon(Icons.undo_rounded),
          onPressed: _undo.isEmpty ? null : _undoStep,
        ),
        IconButton(
          tooltip: 'Redo'.tr,
          icon: const Icon(Icons.redo_rounded),
          onPressed: _redo.isEmpty ? null : _redoStep,
        ),
        IconButton(
          tooltip: 'Save'.tr,
          icon: const Icon(Icons.save_outlined),
          onPressed: _loading || _failure.isNotEmpty
              ? null
              : () => unawaited(_save()),
        ),
      ],
    );
  }

  Widget _bar() {
    if (_selected.isNotEmpty) {
      final single = _selected.length == 1;
      return _BottomActions(
        children: [
          _Action(Icons.rotate_left_rounded, 'Rotate left', () => _rotate(-1)),
          _Action(Icons.rotate_right_rounded, 'Rotate right', () => _rotate(1)),
          _Action(Icons.arrow_back_rounded, 'Earlier', () => _shift(-1)),
          _Action(Icons.arrow_forward_rounded, 'Later', () => _shift(1)),
          _Action(Icons.copy_rounded, 'Duplicate', _duplicate),
          _Action(
            Icons.file_upload_outlined,
            'Extract',
            () => unawaited(_extract()),
          ),
          if (single)
            _Action(
              Icons.edit_outlined,
              'Edit',
              () => unawaited(_openEditor(_chosen.first)),
            ),
          _Action(
            Icons.delete_outline_rounded,
            'Delete',
            _delete,
            danger: true,
          ),
        ],
      );
    }
    return _BottomActions(
      children: [
        _MenuAction(
          icon: Icons.add_rounded,
          label: 'Add pages',
          onSelected: (v) {
            switch (v) {
              case 'pdf':
                unawaited(_pickPdfs());
              case 'library':
                unawaited(_pickFromLibrary());
              case 'images':
                unawaited(_pickImages());
              case 'blank':
                _addBlank();
            }
          },
          items: const [
            PopupMenuItem(value: 'pdf', child: Text('From a PDF file')),
            PopupMenuItem(value: 'library', child: Text('From your library')),
            PopupMenuItem(value: 'images', child: Text('From images')),
            PopupMenuItem(value: 'blank', child: Text('Blank page')),
          ],
        ),
        _MenuAction(
          icon: Icons.build_outlined,
          label: 'Tools',
          onSelected: (v) {
            switch (v) {
              case 'numbers':
                unawaited(_numbers());
              case 'unnumber':
                _apply(removeTagged(_pages, null, numberTag));
              case 'watermark':
                unawaited(_watermark());
              case 'unmark':
                _apply(removeTagged(_pages, null, markTag));
              case 'crop':
                unawaited(_crop());
              case 'reverse':
                _reverse();
              case 'odd':
                _selectWhere((i) => i.isEven);
              case 'even':
                _selectWhere((i) => i.isOdd);
              case 'info':
                unawaited(_info());
            }
          },
          items: const [
            PopupMenuItem(value: 'numbers', child: Text('Page numbers')),
            PopupMenuItem(
              value: 'unnumber',
              child: Text('Remove page numbers'),
            ),
            PopupMenuItem(value: 'watermark', child: Text('Watermark')),
            PopupMenuItem(value: 'unmark', child: Text('Remove watermark')),
            PopupMenuItem(value: 'crop', child: Text('Crop pages')),
            PopupMenuItem(value: 'reverse', child: Text('Reverse order')),
            PopupMenuItem(value: 'odd', child: Text('Select odd pages')),
            PopupMenuItem(value: 'even', child: Text('Select even pages')),
            PopupMenuItem(value: 'info', child: Text('Document info')),
          ],
        ),
        _Action(Icons.call_split_rounded, 'Split', () => unawaited(_split())),
        _Action(Icons.save_outlined, 'Save', () => unawaited(_save())),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failure.isNotEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Text(_failure, textAlign: TextAlign.center),
        ),
      );
    } else {
      body = _grid();
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: _appBar(),
        body: Stack(
          children: [
            Positioned.fill(child: body),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: scheme.scrim.withValues(alpha: 0.35),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _loading || _failure.isNotEmpty ? null : _bar(),
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            children: children,
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onTap, {this.danger = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.tile),
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuAction extends StatelessWidget {
  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    required this.items,
  });

  final IconData icon;
  final String label;
  final ValueChanged<String> onSelected;
  final List<PopupMenuEntry<String>> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      onSelected: onSelected,
      itemBuilder: (context) => items,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    required this.page,
    required this.source,
    required this.images,
    required this.store,
  });

  final PageItem page;
  final PdfSource? source;
  final PageImages images;
  final PictureStore store;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  static const int _width = 300;

  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void didUpdateWidget(_Thumb old) {
    super.didUpdateWidget(old);
    if (old.page.source != widget.page.source ||
        old.page.index != widget.page.index) {
      _release(old.source, old.page);
      _image = null;
      unawaited(_fetch());
    }
  }

  void _release(PdfSource? source, PageItem page) {
    if (source == null || page.blank) return;
    widget.images.release(source, page.index, _width);
  }

  Future<void> _fetch() async {
    final source = widget.source;
    if (source == null || widget.page.blank) return;
    final image = await widget.images.get(source, widget.page.index, _width);
    if (!mounted) return;
    setState(() => _image = image);
  }

  @override
  void dispose() {
    _release(widget.source, widget.page);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final shown = page.shown;
    return AspectRatio(
      aspectRatio: shown.width / shown.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: RotatedBox(
          quarterTurns: page.turns,
          child: CustomPaint(
            painter: PageFace(
              image: _image,
              page: page.size,
              visible: page.visible,
              annotations: page.overlays,
              store: widget.store,
            ),
          ),
        ),
      ),
    );
  }
}
