import 'dart:async';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/app_info.dart';
import 'package:olako/core/edit_history.dart';
import 'package:olako/core/recent_store.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/document_opener.dart';
import 'package:olako/ui/widgets/adaptive.dart';
import 'package:olako/ui/widgets/app_logo.dart';
import 'package:olako/ui/widgets/document_tile.dart';
import 'package:olako/ui/widgets/kind_info.dart';
import 'package:olako/ui/widgets/page_frame.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.recents, super.key});

  final RecentStore recents;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[recents, EditHistory.pending]),
      builder: (context, _) {
        final entries = recents.entries;
        final pending = EditHistory.pending.value;
        final unsaved = recents.all.any((e) => pending.contains(e.id));
        return PageFrame(
          width: 1200,
          child: entries.isEmpty && !unsaved
              ? const _EmptyState()
              : _RecentList(recents: recents, entries: entries),
        );
      },
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.sm,
      children: [
        FilledButton.icon(
          onPressed: () => unawaited(DocumentOpener.openLibrary()),
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Open a document'),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(DocumentOpener.createNote()),
          icon: const Icon(Icons.edit_note_rounded),
          label: const Text('New document'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  static const double _logoSize = 96;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.md,
          children: [
            const AppLogo(size: _logoSize),
            Text(AppInfo.name, style: theme.textTheme.headlineSmall),
            Text(
              'Read Word, PowerPoint, PDF, Excel, OpenDocument, Markdown, text and CSV files. You can also choose this app from the "Open with" list of any file manager.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _OpenButton(),
          ],
        ),
      ),
    );
  }
}

class _RecentList extends StatefulWidget {
  const _RecentList({required this.recents, required this.entries});

  final RecentStore recents;
  final List<RecentEntry> entries;

  @override
  State<_RecentList> createState() => _RecentListState();
}

class _RecentListState extends State<_RecentList> {
  static const int _searchFrom = 6;

  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear the list?'),
        content: const Text(
          'The copies kept by this app will be deleted. Your original files are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok ?? false) await widget.recents.clear();
  }

  Future<void> _actions(BuildContext context, RecentEntry entry) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                entry.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              ),
              title: Text(entry.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () => Navigator.of(sheetContext).pop('pin'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Remove from the list'),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'pin') {
      widget.recents.togglePin(entry.id);
    } else if (choice == 'remove') {
      unawaited(widget.recents.remove(entry.id));
    }
  }

  List<RecentEntry> _visible() {
    final needle = _query.text.trim().toLowerCase();
    final shown = <RecentEntry>[
      for (final entry in widget.entries)
        if (needle.isEmpty || entry.name.toLowerCase().contains(needle)) entry,
    ];
    return <RecentEntry>[
      for (final entry in shown)
        if (entry.pinned) entry,
      for (final entry in shown)
        if (!entry.pinned) entry,
    ];
  }

  Widget _brand(ThemeData theme) {
    return Row(
      spacing: AppSpacing.md,
      children: [
        const AppLogo(size: 44),
        Expanded(
          child: Text(AppInfo.name, style: theme.textTheme.headlineSmall),
        ),
      ],
    );
  }

  Widget _search() {
    return TextField(
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
    );
  }

  Widget _label(ThemeData theme) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Recent',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_confirmClear(context)),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  List<Widget> _tiles(List<RecentEntry> visible) {
    return <Widget>[
      for (final entry in visible)
        _RecentTile(
          key: ValueKey<String>(entry.id),
          entry: entry,
          onRemove: () => unawaited(widget.recents.remove(entry.id)),
          onActions: () => unawaited(_actions(context, entry)),
        ),
    ];
  }

  Future<void> _discard(RecentEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard these changes?'),
        content: const Text('The unsaved edits will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard changes'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    await EditHistory.deleteDraft(entry.id);
    if (entry.fresh) await widget.recents.remove(entry.id);
  }

  List<Widget> _unsaved(ThemeData theme, Set<String> pending) {
    final items = <RecentEntry>[
      for (final entry in widget.recents.all)
        if (pending.contains(entry.id)) entry,
    ];
    if (items.isEmpty) return const <Widget>[];
    final scheme = theme.colorScheme;
    return <Widget>[
      Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Text(
          'Unsaved changes',
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
        ),
      ),
      for (final entry in items)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Material(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(
                Icons.edit_note_rounded,
                color: scheme.onPrimaryContainer,
              ),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('Tap to continue editing'),
              trailing: IconButton(
                tooltip: 'Discard changes'.tr,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => unawaited(_discard(entry)),
              ),
              onTap: () => DocumentOpener.edit(entry),
            ),
          ),
        ),
      const SizedBox(height: AppSpacing.sm),
    ];
  }

  List<Widget> _list(
    ThemeData theme,
    List<RecentEntry> visible,
    double width,
    Set<String> pending,
  ) {
    return <Widget>[
      if (_query.text.isEmpty) ..._unsaved(theme, pending),
      if (widget.entries.isNotEmpty) _label(theme),
      if (visible.isEmpty && widget.entries.isNotEmpty)
        const Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'Nothing matches your search.',
            textAlign: TextAlign.center,
          ),
        ),
      ...tileRows(Adaptive.columns(width), _tiles(visible)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: EditHistory.pending,
      builder: (context, pending, _) => _content(context, pending),
    );
  }

  Widget _content(BuildContext context, Set<String> pending) {
    final theme = Theme.of(context);
    final visible = _visible();
    final size = MediaQuery.sizeOf(context);
    final searching = widget.entries.length >= _searchFrom;
    const padding = EdgeInsets.only(bottom: AppSpacing.lg);
    if (Adaptive.twoPane(size)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.xl,
        children: [
          SizedBox(
            width: 300,
            child: ListView(
              padding: padding,
              children: [
                _brand(theme),
                const SizedBox(height: AppSpacing.lg),
                const _OpenButton(),
                if (searching) ...[
                  const SizedBox(height: AppSpacing.lg),
                  _search(),
                ],
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => ListView(
                padding: padding,
                children: _list(theme, visible, box.maxWidth, pending),
              ),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: padding,
        children: [
          _brand(theme),
          const SizedBox(height: AppSpacing.lg),
          const _OpenButton(),
          const SizedBox(height: AppSpacing.lg),
          if (searching)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _search(),
            ),
          ..._list(theme, visible, box.maxWidth, pending),
        ],
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.entry,
    required this.onRemove,
    required this.onActions,
    super.key,
  });

  final RecentEntry entry;
  final VoidCallback onRemove;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle =
        '${KindInfo.label(entry.kind)} · ${KindInfo.size(entry.size)} · ${KindInfo.when(entry.openedAt)}';
    return Dismissible(
      key: ValueKey<String>('dismiss-${entry.id}'),
      onDismissed: (_) => onRemove(),
      background: _DismissBackground(
        color: scheme.errorContainer,
        iconColor: scheme.onErrorContainer,
        alignment: AlignmentDirectional.centerStart,
      ),
      secondaryBackground: _DismissBackground(
        color: scheme.errorContainer,
        iconColor: scheme.onErrorContainer,
        alignment: AlignmentDirectional.centerEnd,
      ),
      child: DocumentTile(
        kind: entry.kind,
        title: entry.name,
        meta: subtitle,
        progress: entry.progress,
        pinned: entry.pinned,
        onLongPress: onActions,
        onTap: () => DocumentOpener.openRecent(entry),
      ),
    );
  }
}

class _DismissBackground extends StatelessWidget {
  const _DismissBackground({
    required this.color,
    required this.iconColor,
    required this.alignment,
  });

  final Color color;
  final Color iconColor;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Icon(Icons.delete_outline_rounded, color: iconColor),
          ),
        ),
      ),
    );
  }
}
