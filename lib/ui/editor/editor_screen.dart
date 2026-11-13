import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/core/edit_history.dart';
import 'package:olako/core/recent_store.dart';
import 'package:olako/export/export_screen.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/reader/markdown_reader.dart';
import 'package:olako/reader/text_direction.dart';
import 'package:olako/settings/app_settings.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/editor/markdown_actions.dart';
import 'package:olako/ui/viewer/document_view.dart';

enum _SaveState { saved, saving, dirty, failed }

TextDocument _parse(String text) => readMarkdown(text);

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.entry,
    required this.recents,
    required this.settings,
    this.resume = false,
    super.key,
  });

  final bool resume;
  final RecentEntry entry;
  final RecentStore recents;
  final AppSettings settings;

  static bool canEdit(DocumentKind kind) =>
      kind == DocumentKind.markdown ||
      kind == DocumentKind.text ||
      kind == DocumentKind.table;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  static const double _splitWidth = 720;
  static const Duration _commitDelay = Duration(milliseconds: 700);
  static const Duration _draftDelay = Duration(milliseconds: 1200);
  static const Duration _previewDelay = Duration(milliseconds: 350);

  final TextEditingController _controller = TextEditingController();
  final TextEditingController _find = TextEditingController();
  final TextEditingController _replace = TextEditingController();
  final FocusNode _focus = FocusNode();
  late final EditHistory _history = EditHistory(widget.entry.id);
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  final ValueNotifier<TextDocument?> _doc = ValueNotifier<TextDocument?>(null);
  final ValueNotifier<String> _stats = ValueNotifier<String>('');
  final ValueNotifier<TextDirection> _direction = ValueNotifier<TextDirection>(
    TextDirection.ltr,
  );
  final ValueNotifier<bool> _finding = ValueNotifier<bool>(false);

  Timer? _commitTimer;
  Timer? _draftTimer;
  bool _closedByUser = false;
  Timer? _previewTimer;
  bool _ready = false;
  bool _failedToLoad = false;
  bool _crlf = false;
  bool _applying = false;
  bool _previewTab = false;
  int _parseRun = 0;
  String _saved = '';
  String _last = '';
  _SaveState _state = _SaveState.saved;

  bool get _canPreview => widget.entry.kind == DocumentKind.markdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.entry.path).readAsBytes();
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.startsWith('﻿')) text = text.substring(1);
      _crlf = text.contains('\r\n');
      if (_crlf) text = text.replaceAll('\r\n', '\n');
      _saved = text;
      _last = text;
      _controller.text = text;
      await _history.load(text);
      _controller.addListener(_onController);
      final draft = await EditHistory.readDraft(widget.entry.id);
      if (!mounted) return;
      setState(() => _ready = true);
      _refresh();
      if (draft != null && draft != text) {
        if (widget.resume) {
          _controller.text = draft;
          _commit();
        } else {
          unawaited(_offerDraft(draft));
        }
      }
    } on Object {
      if (mounted) setState(() => _failedToLoad = true);
    }
  }

  void _onController() {
    if (_applying) return;
    final text = _controller.text;
    if (text == _last) return;
    _last = text;
    _changed(commitNow: false);
  }

  void _changed({required bool commitNow}) {
    _state = _controller.text == _saved ? _SaveState.saved : _SaveState.dirty;
    _commitTimer?.cancel();
    if (commitNow) {
      _commit();
    } else {
      _commitTimer = Timer(_commitDelay, _commit);
    }
    _draftTimer?.cancel();
    if (_state == _SaveState.dirty) {
      _draftTimer = Timer(_draftDelay, () => unawaited(_writeDraft()));
    }
    _previewTimer?.cancel();
    _previewTimer = Timer(_previewDelay, _refresh);
    _tick.value++;
  }

  void _commit() {
    _commitTimer?.cancel();
    final cursor = _controller.selection.isValid
        ? _controller.selection.extentOffset
        : _controller.text.length;
    _history.record(_controller.text, cursor);
    _tick.value++;
  }

  bool get _previewVisible {
    if (!_canPreview) return false;
    return MediaQuery.sizeOf(context).width >= _splitWidth || _previewTab;
  }

  void _refresh() {
    final text = _controller.text;
    _direction.value = (firstStrongIsRtl(text) ?? false)
        ? TextDirection.rtl
        : TextDirection.ltr;
    final words = RegExp(r'\S+').allMatches(text).length;
    _stats.value = '$words words · ${text.length} characters';
    if (!_canPreview || !_previewVisible) return;
    final run = ++_parseRun;
    if (text.length < 40000) {
      _doc.value = _parse(text);
      return;
    }
    unawaited(
      Isolate.run(() => _parse(text)).then((doc) {
        if (mounted && run == _parseRun) _doc.value = doc;
      }),
    );
  }

  Future<bool> _save() async {
    _draftTimer?.cancel();
    final text = _controller.text;
    if (text == _saved) {
      _state = _SaveState.saved;
      _tick.value++;
      unawaited(EditHistory.deleteDraft(widget.entry.id));
      return true;
    }
    _state = _SaveState.saving;
    _tick.value++;
    var ok = true;
    try {
      final out = _crlf ? text.replaceAll('\n', '\r\n') : text;
      final file = File(widget.entry.path);
      await file.writeAsString(out, flush: true);
      _saved = text;
      widget.recents.updateSize(widget.entry.id, await file.length());
      widget.recents.settle(widget.entry.id);
    } on Object {
      ok = false;
    }
    if (ok && _controller.text == _saved) {
      unawaited(EditHistory.deleteDraft(widget.entry.id));
    }
    _state = ok
        ? (_controller.text == _saved ? _SaveState.saved : _SaveState.dirty)
        : _SaveState.failed;
    _commit();
    unawaited(_history.save());
    return ok;
  }

  Future<void> _writeDraft() async {
    _draftTimer?.cancel();
    if (_controller.text == _saved) {
      await EditHistory.deleteDraft(widget.entry.id);
      return;
    }
    await EditHistory.writeDraft(widget.entry.id, _controller.text);
    await _history.save();
  }

  Future<void> _offerDraft(String draft) async {
    final restore = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore unsaved changes?'),
        content: const Text(
          'Some changes from the last time you edited this document were never saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Discard changes'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (restore ?? false) {
      _controller.text = draft;
      _commit();
    } else {
      await EditHistory.deleteDraft(widget.entry.id);
    }
  }

  void _apply(EditSnapshot snapshot) {
    _applying = true;
    _controller.value = TextEditingValue(
      text: snapshot.text,
      selection: TextSelection.collapsed(
        offset: snapshot.cursor < 0
            ? 0
            : (snapshot.cursor > snapshot.text.length
                  ? snapshot.text.length
                  : snapshot.cursor),
      ),
    );
    _applying = false;
    _last = snapshot.text;
    _changed(commitNow: false);
    _commitTimer?.cancel();
    unawaited(_history.save());
    _tick.value++;
  }

  void _undo() {
    if (_commitTimer?.isActive ?? false) _commit();
    final snapshot = _history.undo();
    if (snapshot != null) _apply(snapshot);
  }

  void _redo() {
    final snapshot = _history.redo();
    if (snapshot != null) _apply(snapshot);
  }

  void _act(TextEditingValue Function(TextEditingValue value) change) {
    if (_commitTimer?.isActive ?? false) _commit();
    _controller.value = change(_controller.value);
    _last = _controller.text;
    _changed(commitNow: true);
    _focus.requestFocus();
  }

  RegExp _pattern() => RegExp(RegExp.escape(_find.text), caseSensitive: false);

  void _findNext({required bool forward}) {
    final query = _find.text;
    if (query.isEmpty) return;
    final text = _controller.text;
    final matches = _pattern().allMatches(text).toList();
    if (matches.isEmpty) {
      _say('No matches');
      return;
    }
    final selection = _controller.selection;
    final from = selection.isValid ? selection.end : 0;
    RegExpMatch? pick;
    if (forward) {
      for (final match in matches) {
        if (match.start >= from) {
          pick = match;
          break;
        }
      }
      pick ??= matches.first;
    } else {
      final before = selection.isValid ? selection.start : text.length;
      for (final match in matches.reversed) {
        if (match.end <= before) {
          pick = match;
          break;
        }
      }
      pick ??= matches.last;
    }
    _controller.selection = TextSelection(
      baseOffset: pick.start,
      extentOffset: pick.end,
    );
    _focus.requestFocus();
  }

  void _replaceCurrent() {
    final selection = _controller.selection;
    if (_find.text.isEmpty || !selection.isValid || selection.isCollapsed) {
      _findNext(forward: true);
      return;
    }
    final selected = _controller.text.substring(selection.start, selection.end);
    if (selected.toLowerCase() != _find.text.toLowerCase()) {
      _findNext(forward: true);
      return;
    }
    _act(
      (value) => TextEditingValue(
        text: value.text.replaceRange(
          selection.start,
          selection.end,
          _replace.text,
        ),
        selection: TextSelection.collapsed(
          offset: selection.start + _replace.text.length,
        ),
      ),
    );
    _findNext(forward: true);
  }

  void _replaceAll() {
    if (_find.text.isEmpty) return;
    final count = _pattern().allMatches(_controller.text).length;
    if (count == 0) {
      _say('No matches');
      return;
    }
    final replacement = _replace.text;
    _act(
      (value) => TextEditingValue(
        text: value.text.replaceAll(_pattern(), replacement),
        selection: const TextSelection.collapsed(offset: 0),
      ),
    );
    _say('$count replaced');
  }

  void _export() {
    final blocks = readMarkdown(_controller.text).blocks;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          blocks: blocks,
          name: widget.entry.name,
          settings: widget.settings,
          baseDir: File(widget.entry.path).parent.path,
        ),
      ),
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _dropIfFresh() async {
    final current = widget.recents.byId(widget.entry.id);
    if (current != null && current.fresh) {
      await widget.recents.remove(widget.entry.id);
    }
  }

  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    _commit();
    if (_controller.text == _saved) {
      await EditHistory.deleteDraft(widget.entry.id);
      await _dropIfFresh();
      _closedByUser = true;
      navigator.pop();
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
      await EditHistory.deleteDraft(widget.entry.id);
      await _dropIfFresh();
      _closedByUser = true;
      navigator.pop();
      return;
    }
    if (choice != 'save') return;
    final ok = await _save();
    if (ok) {
      _closedByUser = true;
      navigator.pop();
      return;
    }
    if (!mounted) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Couldn't save this file"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard changes'),
          ),
        ],
      ),
    );
    if (discard ?? false) {
      await EditHistory.deleteDraft(widget.entry.id);
      await _dropIfFresh();
      _closedByUser = true;
      navigator.pop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _ready) {
      _commit();
      unawaited(_writeDraft());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commitTimer?.cancel();
    _draftTimer?.cancel();
    _previewTimer?.cancel();
    if (_ready && !_closedByUser) {
      if (_controller.text != _saved) {
        unawaited(EditHistory.writeDraft(widget.entry.id, _controller.text));
      } else {
        final recents = widget.recents;
        final id = widget.entry.id;
        scheduleMicrotask(() {
          if (recents.byId(id)?.fresh ?? false) unawaited(recents.remove(id));
        });
      }
    }
    if (_ready) {
      _history.record(_controller.text, _controller.selection.extentOffset);
      unawaited(_history.save());
    }
    _controller.dispose();
    _find.dispose();
    _replace.dispose();
    _focus.dispose();
    _tick.dispose();
    _doc.dispose();
    _stats.dispose();
    _direction.dispose();
    _finding.dispose();
    super.dispose();
  }

  Widget _statusText(ThemeData theme) {
    final label = switch (_state) {
      _SaveState.saved => 'Saved',
      _SaveState.saving => 'Saving…',
      _SaveState.dirty => 'Not saved',
      _SaveState.failed => "Couldn't save this file",
    };
    return Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: _state == _SaveState.failed
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _toolbar(ThemeData theme) {
    Widget tool(IconData icon, String tip, VoidCallback onTap) {
      return IconButton(
        tooltip: tip.tr,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon),
        onPressed: onTap,
      );
    }

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
          children: [
            tool(Icons.title_rounded, 'Heading', () => _act(cycleHeading)),
            tool(
              Icons.format_bold_rounded,
              'Bold',
              () => _act((v) => wrapSelection(v, '**', '**', 'bold')),
            ),
            tool(
              Icons.format_italic_rounded,
              'Italic',
              () => _act((v) => wrapSelection(v, '*', '*', 'italic')),
            ),
            tool(
              Icons.strikethrough_s_rounded,
              'Strikethrough',
              () => _act((v) => wrapSelection(v, '~~', '~~', 'text')),
            ),
            tool(
              Icons.code_rounded,
              'Inline code',
              () => _act((v) => wrapSelection(v, '`', '`', 'code')),
            ),
            tool(
              Icons.format_list_bulleted_rounded,
              'Bulleted list',
              () => _act(
                (v) => toggleLinePrefix(
                  v,
                  (i) => '- ',
                  RegExp(r'^[-*+] (?!\[[ xX]\] )'),
                ),
              ),
            ),
            tool(
              Icons.format_list_numbered_rounded,
              'Numbered list',
              () => _act(
                (v) => toggleLinePrefix(
                  v,
                  (i) => '${i + 1}. ',
                  RegExp(r'^\d+[.)] '),
                ),
              ),
            ),
            tool(
              Icons.checklist_rounded,
              'Task list',
              () => _act(
                (v) => toggleLinePrefix(
                  v,
                  (i) => '- [ ] ',
                  RegExp(r'^- \[[ xX]\] '),
                ),
              ),
            ),
            tool(
              Icons.format_quote_rounded,
              'Quote',
              () => _act(
                (v) => toggleLinePrefix(v, (i) => '> ', RegExp(r'^> ?')),
              ),
            ),
            tool(Icons.link_rounded, 'Link', () => _act(insertLink)),
            tool(
              Icons.data_object_rounded,
              'Code block',
              () => _act((v) => wrapSelection(v, '```\n', '\n```', 'code')),
            ),
            tool(
              Icons.table_chart_outlined,
              'Table',
              () => _act(
                (v) => insertBlock(
                  v,
                  '| Column 1 | Column 2 |\n| --- | --- |\n|  |  |',
                ),
              ),
            ),
            tool(
              Icons.horizontal_rule_rounded,
              'Divider',
              () => _act((v) => insertBlock(v, '---')),
            ),
            tool(
              Icons.format_indent_increase_rounded,
              'Indent',
              () => _act((v) => shiftIndent(v, outward: false)),
            ),
            tool(
              Icons.format_indent_decrease_rounded,
              'Outdent',
              () => _act((v) => shiftIndent(v, outward: true)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _findBar(ThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: _finding,
      builder: (context, open, _) {
        if (!open) return const SizedBox.shrink();
        return Material(
          color: theme.colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              spacing: AppSpacing.sm,
              children: [
                Row(
                  spacing: AppSpacing.xxs,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _find,
                        decoration: InputDecoration(
                          hintText: 'Find'.tr,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _findNext(forward: true),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous'.tr,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      onPressed: () => _findNext(forward: false),
                    ),
                    IconButton(
                      tooltip: 'Next'.tr,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: () => _findNext(forward: true),
                    ),
                    IconButton(
                      tooltip: 'Close'.tr,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _finding.value = false,
                    ),
                  ],
                ),
                Row(
                  spacing: AppSpacing.xxs,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _replace,
                        decoration: InputDecoration(
                          hintText: 'Replace with'.tr,
                          isDense: true,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _replaceCurrent,
                      child: const Text('Replace'),
                    ),
                    TextButton(
                      onPressed: _replaceAll,
                      child: const Text('Replace all'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _editorPane(ThemeData theme) {
    final size = 14.0 * widget.settings.readerScale / 100;
    return Column(
      children: [
        _findBar(theme),
        Expanded(
          child: ValueListenableBuilder<TextDirection>(
            valueListenable: _direction,
            builder: (context, direction, _) => TextField(
              controller: _controller,
              focusNode: _focus,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textDirection: direction,
              inputFormatters: [ListContinuation()],
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: size,
                height: 1.5,
              ),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.all(AppSpacing.md),
              ),
            ),
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: _stats,
          builder: (context, stats, _) => Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xxs,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                stats,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        _toolbar(theme),
      ],
    );
  }

  Widget _previewPane() {
    return ValueListenableBuilder<TextDocument?>(
      valueListenable: _doc,
      builder: (context, doc, _) {
        if (doc == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => DocumentView(
            blocks: doc.blocks,
            baseSizePt: doc.baseSizePt,
            readerScale: widget.settings.readerScale,
            initialPosition: 0,
            onProgress: (position, progress) {},
            markdown: true,
          ),
        );
      },
    );
  }

  Widget _body(ThemeData theme) {
    final wide = MediaQuery.sizeOf(context).width >= _splitWidth;
    if (!_canPreview) return _editorPane(theme);
    if (wide) {
      return Row(
        children: [
          Expanded(child: _editorPane(theme)),
          const VerticalDivider(width: 1),
          Expanded(child: _previewPane()),
        ],
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xxs,
          ),
          child: SegmentedButton<bool>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Write')),
              ButtonSegment(value: true, label: Text('Preview')),
            ],
            selected: {_previewTab},
            onSelectionChanged: (selection) {
              setState(() => _previewTab = selection.first);
              if (_previewTab) _refresh();
            },
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _previewTab ? 1 : 0,
            children: [_editorPane(theme), _previewPane()],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_failedToLoad) {
      return Scaffold(
        appBar: AppBar(title: w.Text(widget.entry.name)),
        body: const Center(child: Text("Couldn't open this document")),
      );
    }
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: w.Text(widget.entry.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: ValueListenableBuilder<int>(
            valueListenable: _tick,
            builder: (context, _, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                w.Text(
                  widget.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                _statusText(theme),
              ],
            ),
          ),
          actions: [
            ValueListenableBuilder<int>(
              valueListenable: _tick,
              builder: (context, _, __) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Undo'.tr,
                    icon: const Icon(Icons.undo_rounded),
                    onPressed:
                        _history.canUndo || (_commitTimer?.isActive ?? false)
                        ? _undo
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Redo'.tr,
                    icon: const Icon(Icons.redo_rounded),
                    onPressed: _history.canRedo ? _redo : null,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Find and replace'.tr,
              icon: const Icon(Icons.find_replace_rounded),
              onPressed: () => _finding.value = !_finding.value,
            ),
            IconButton(
              tooltip: 'Save'.tr,
              icon: const Icon(Icons.save_outlined),
              onPressed: () => unawaited(_save()),
            ),
            PopupMenuButton<String>(
              onSelected: (_) => _export(),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'pdf',
                  child: Text('Convert to PDF'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(top: false, child: _body(theme)),
      ),
    );
  }
}
