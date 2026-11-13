import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/core/library_index.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/document_opener.dart';
import 'package:olako/ui/widgets/adaptive.dart';
import 'package:olako/ui/widgets/document_tile.dart';
import 'package:olako/ui/widgets/kind_info.dart';
import 'package:olako/ui/widgets/page_frame.dart';

enum _Sort { newest, name, size }

class _Item {
  const _Item(this.file, this.kind, this.folder);

  final LibraryFile file;
  final DocumentKind kind;
  final String folder;
}

String _folderOf(String path) {
  const prefix = '/storage/emulated/0';
  final cut = path.lastIndexOf('/');
  var folder = cut <= 0 ? '/' : path.substring(0, cut);
  if (folder.startsWith(prefix)) folder = folder.substring(prefix.length);
  return folder.isEmpty ? '/' : folder;
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  final TextEditingController _query = TextEditingController();
  final LibraryIndex _index = LibraryIndex.instance;
  List<_Item> _items = const <_Item>[];
  DocumentKind? _filter;
  _Sort _sort = _Sort.newest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index.addListener(_onIndex);
    _rebuildItems();
    unawaited(_index.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _index.removeListener(_onIndex);
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _index.denied) {
      unawaited(_index.refresh());
    }
  }

  void _onIndex() {
    if (!mounted) return;
    setState(_rebuildItems);
  }

  void _rebuildItems() {
    final items = <_Item>[];
    for (final file in _index.files) {
      final kind = detectKind(file.name, '');
      if (kind == null) continue;
      items.add(_Item(file, kind, _folderOf(file.path)));
    }
    _items = items;
    final chosen = _filter;
    if (chosen != null && !items.any((item) => item.kind == chosen)) {
      _filter = null;
    }
  }

  Future<void> _choose() async {
    await DocumentOpener.pick();
  }

  List<_Item> _visible() {
    final needle = _query.text.trim().toLowerCase();
    final shown = <_Item>[
      for (final item in _items)
        if ((_filter == null || item.kind == _filter) &&
            (needle.isEmpty ||
                item.file.name.toLowerCase().contains(needle) ||
                item.folder.toLowerCase().contains(needle)))
          item,
    ];
    switch (_sort) {
      case _Sort.newest:
        shown.sort((a, b) => b.file.modified.compareTo(a.file.modified));
      case _Sort.name:
        shown.sort(
          (a, b) =>
              a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase()),
        );
      case _Sort.size:
        shown.sort((a, b) => b.file.size.compareTo(a.file.size));
    }
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents on this phone'),
        actions: [
          IconButton(
            tooltip: 'Choose with the file picker'.tr,
            onPressed: () => unawaited(_choose()),
            icon: const Icon(Icons.folder_open_rounded),
          ),
          PopupMenuButton<_Sort>(
            tooltip: 'Sort'.tr,
            icon: const Icon(Icons.sort_rounded),
            initialValue: _sort,
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _Sort.newest,
                child: Text('Newest first'),
              ),
              const PopupMenuItem(value: _Sort.name, child: Text('Name')),
              const PopupMenuItem(
                value: _Sort.size,
                child: Text('Largest first'),
              ),
            ],
          ),
          if (!_index.denied)
            IconButton(
              tooltip: 'Refresh'.tr,
              onPressed: _index.scanning
                  ? null
                  : () => unawaited(_index.refresh()),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(child: PageFrame(width: 1200, child: _body())),
    );
  }

  Widget _body() {
    if (_index.denied && _items.isEmpty) {
      return _Permission(
        onAllow: () => unawaited(DocumentService.requestStorage()),
        onPick: () => unawaited(_choose()),
      );
    }
    if (!_index.loaded || (_items.isEmpty && _index.scanning)) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.lg,
          children: [
            CircularProgressIndicator(),
            Text('Looking for documents…'),
          ],
        ),
      );
    }
    return _ready();
  }

  Widget _ready() {
    final visible = _visible();
    final kinds = <DocumentKind>{for (final item in _items) item.kind};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_index.scanning)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        TextField(
          controller: _query,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search'.tr,
            prefixIcon: const Icon(Icons.search_rounded),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              ),
              for (final kind in DocumentKind.values)
                if (kinds.contains(kind))
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: AppSpacing.sm,
                    ),
                    child: ChoiceChip(
                      label: w.Text(KindInfo.label(kind)),
                      selected: _filter == kind,
                      onSelected: (_) => setState(() => _filter = kind),
                    ),
                  ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text(
                      _items.isEmpty
                          ? 'No supported documents were found on this phone.'
                          : 'Nothing matches your search.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final columns = Adaptive.columns(box.maxWidth);
                    final rows = (visible.length + columns - 1) ~/ columns;
                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      itemCount: rows,
                      itemBuilder: (context, row) {
                        final start = row * columns;
                        final end = math.min(visible.length, start + columns);
                        return TileRow(
                          columns: columns,
                          items: <Widget>[
                            for (var i = start; i < end; i++)
                              _LibraryTile(item: visible[i]),
                          ],
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Permission extends StatelessWidget {
  const _Permission({required this.onAllow, required this.onPick});

  final VoidCallback onAllow;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.lg,
          children: [
            Icon(
              Icons.folder_copy_outlined,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            Text(
              "To list the documents on this phone, o'lako needs permission to see your files. It only reads the ones you open.",
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            FilledButton.icon(
              onPressed: onAllow,
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text('Allow access to files'),
            ),
            OutlinedButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Choose with the file picker'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({required this.item});

  final _Item item;

  @override
  Widget build(BuildContext context) {
    final file = item.file;
    return DocumentTile(
      kind: item.kind,
      title: file.name,
      folder: item.folder,
      meta:
          '${KindInfo.label(item.kind)} · ${KindInfo.size(file.size)} · ${KindInfo.when(file.modified)}',
      onTap: () => unawaited(DocumentOpener.openFile(file.path, file.name)),
    );
  }
}
