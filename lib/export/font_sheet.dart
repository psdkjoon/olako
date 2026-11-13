import 'dart:async';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/export/font_library.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/theme/app_spacing.dart';

Future<String?> pickFont(
  BuildContext context, {
  required String current,
  required bool allowSame,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FontSheet(current: current, allowSame: allowSame),
  );
}

class _FontSheet extends StatefulWidget {
  const _FontSheet({required this.current, required this.allowSame});

  final String current;
  final bool allowSame;

  @override
  State<_FontSheet> createState() => _FontSheetState();
}

class _FontSheetState extends State<_FontSheet> {
  Set<String> _installed = <String>{};
  final Set<String> _busy = <String>{};
  final Map<String, double> _progress = <String, double>{};
  String _error = '';
  String _search = '';
  String _prefix = '';

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final found = await FontLibrary.installed();
    final prefix = await FontLibrary.specFor('');
    if (mounted) {
      setState(() {
        _installed = found;
        _prefix = prefix;
      });
    }
  }

  void _choose(String spec) {
    Navigator.of(context).pop(spec);
  }

  Future<void> _use(FontEntry entry) async {
    if (_installed.contains(entry.key)) {
      _choose('$_prefix${entry.key}');
      return;
    }
    if (_busy.contains(entry.key)) return;
    setState(() {
      _busy.add(entry.key);
      _progress[entry.key] = 0;
      _error = '';
    });
    final ok = await FontLibrary.download(entry, (value) {
      if (mounted) setState(() => _progress[entry.key] = value);
    });
    if (!mounted) return;
    setState(() => _busy.remove(entry.key));
    if (!ok) {
      setState(() => _error = "Couldn't download this font");
      return;
    }
    await _refresh();
    if (!mounted) return;
    _choose('$_prefix${entry.key}');
  }

  Future<void> _addFile() async {
    final path = await DocumentService.pick();
    if (path == null || !mounted) return;
    final key = await FontLibrary.importFile(path);
    if (!mounted) return;
    if (key == null) {
      setState(() => _error = 'Choose a .ttf or .otf font file');
      return;
    }
    _choose('$_prefix$key');
  }

  Future<void> _delete(String key) async {
    await FontLibrary.remove(key);
    await _refresh();
  }

  Widget _option({
    required String title,
    required bool selected,
    required VoidCallback onTap,
    Widget? trailing,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer.withValues(
        alpha: 0.6,
      ),
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
      ),
      title: w.Text(title),
      subtitle: subtitle == null ? null : w.Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _header(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xxs,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    final catalogKeys = <String>{
      for (final entry in FontLibrary.catalog) entry.key,
    };
    final mine = _installed.where((key) => !catalogKeys.contains(key)).toList()
      ..sort();
    final query = _search.trim().toLowerCase();
    final groups = <String>[
      FontLibrary.arabicGroup,
      FontLibrary.sansGroup,
      FontLibrary.serifGroup,
      FontLibrary.monoGroup,
    ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: TextField(
              onChanged: (value) => setState(() => _search = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Search'.tr,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                _error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (query.isEmpty) ...[
                  if (widget.allowSame)
                    _option(
                      title: 'Same as text'.tr,
                      selected: current == 'same',
                      onTap: () => _choose('same'),
                    ),
                  _option(
                    title: 'Sans-serif'.tr,
                    selected: current == 'sans',
                    onTap: () => _choose('sans'),
                  ),
                  _option(
                    title: 'Serif'.tr,
                    selected: current == 'serif',
                    onTap: () => _choose('serif'),
                  ),
                  _option(
                    title: 'Monospace'.tr,
                    selected: current == 'mono',
                    onTap: () => _choose('mono'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_rounded),
                    title: const Text('Add a font file'),
                    onTap: () => unawaited(_addFile()),
                  ),
                ],
                if (query.isEmpty && mine.isNotEmpty) _header('My fonts'.tr),
                if (query.isEmpty)
                  for (final key in mine)
                    _option(
                      title: key.replaceAll('_', ' '),
                      selected: current == '$_prefix$key',
                      onTap: () => _choose('$_prefix$key'),
                      trailing: IconButton(
                        tooltip: 'Delete'.tr,
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => unawaited(_delete(key)),
                      ),
                    ),
                for (final group in groups) ...[
                  if (FontLibrary.catalog.any(
                    (e) =>
                        e.group == group &&
                        e.family.toLowerCase().contains(query),
                  ))
                    _header(group.tr),
                  for (final entry in FontLibrary.catalog)
                    if (entry.group == group &&
                        entry.family.toLowerCase().contains(query))
                      _option(
                        title: entry.family,
                        selected:
                            _installed.contains(entry.key) &&
                            current == '$_prefix${entry.key}',
                        onTap: () => unawaited(_use(entry)),
                        trailing: _busy.contains(entry.key)
                            ? SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  value: (_progress[entry.key] ?? 0) > 0
                                      ? _progress[entry.key]
                                      : null,
                                ),
                              )
                            : (_installed.contains(entry.key)
                                  ? IconButton(
                                      tooltip: 'Delete'.tr,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      onPressed: () =>
                                          unawaited(_delete(entry.key)),
                                    )
                                  : const Icon(Icons.download_rounded)),
                      ),
                ],
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
