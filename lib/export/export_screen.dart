import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/export/color_dialog.dart';
import 'package:olako/export/font_library.dart';
import 'package:olako/export/font_sheet.dart';
import 'package:olako/export/pdf_blocks.dart';
import 'package:olako/export/pdf_options.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/settings/app_settings.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/document_opener.dart';
import 'package:olako/ui/viewer/doc_style.dart';
import 'package:olako/ui/viewer/pdf_view.dart';
import 'package:olako/ui/widgets/adaptive.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({
    required this.blocks,
    required this.name,
    required this.settings,
    this.baseDir = '',
    super.key,
  });

  final List<DocBlock> blocks;
  final String name;
  final AppSettings settings;
  final String baseDir;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

Future<List<Object?>> _serialize(List<DocBlock> blocks, String base) {
  return Isolate.run(() => serializeBlocks(blocks, base));
}

class _ExportScreenState extends State<ExportScreen> {
  late final PdfOptions _options = PdfOptions.fromJson(
    widget.settings.pdfOptions,
  );
  late List<PdfPreset> _mine = parseStyles(widget.settings.pdfStyles);
  bool _busy = false;
  PdfExportResult? _result;
  String _error = '';
  int _version = 0;

  String get _stem {
    final stem = widget.name.replaceFirst(RegExp(r'\.[^./\\]+$'), '');
    return stem.isEmpty ? 'document' : stem;
  }

  String get _fileName => '$_stem.pdf';

  void _set(String key, Object value) {
    setState(() => _options.set(key, value));
    widget.settings.storePdfOptions(_options.toJson());
  }

  void _preset(PdfPreset preset) {
    setState(() => _options.applyPreset(preset));
    widget.settings.storePdfOptions(_options.toJson());
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _dateText() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final text = '${now.year}-${two(now.month)}-${two(now.day)}';
    if (_options.value('digits') != 'persian') return text;
    return String.fromCharCodes([
      for (final unit in text.codeUnits)
        unit >= 0x30 && unit <= 0x39 ? unit - 0x30 + 0x6F0 : unit,
    ]);
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    final blocks = widget.blocks;
    final base = widget.baseDir;
    List<Object?> data;
    try {
      data = await _serialize(blocks, base);
    } on Object {
      try {
        data = serializeBlocks(blocks, base);
      } on Object {
        data = const <Object?>[];
      }
    }
    if (!mounted) return;
    if (data.isEmpty) {
      setState(() => _busy = false);
      _say('There is nothing to convert');
      return;
    }
    final result = await DocumentService.exportPdf(<String, Object?>{
      'name': _fileName,
      'title': _stem,
      'date': _dateText(),
      'rtl': blocksAreRtl(blocks) ?? false,
      'options': _options.toExport(),
      'blocks': data,
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result.ok ? result : null;
      _error = result.ok ? '' : result.error;
      _version++;
    });
    if (!result.ok) {
      _say("Couldn't create the PDF");
      return;
    }
    if (!Adaptive.twoPane(MediaQuery.sizeOf(context))) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _PreviewScreen(
            result: result,
            version: _version,
            name: _fileName,
          ),
        ),
      );
    }
  }

  Future<void> _pickFont(PdfOption option) async {
    final picked = await pickFont(
      context,
      current: _options.text(option.key),
      allowSame: option.same,
    );
    if (picked != null && mounted) _set(option.key, picked);
  }

  Future<void> _saveStyle() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save as style'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Style name'.tr,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    for (final preset in PdfSchema.presets) {
      if (preset.name.tr == name || preset.name == name) {
        _say('Choose another name');
        return;
      }
    }
    final style = PdfPreset(name, _options.styleValues());
    setState(() {
      _mine = <PdfPreset>[
        for (final item in _mine)
          if (item.name != name) item,
        style,
      ];
    });
    widget.settings.storePdfStyles(encodeStyles(_mine));
  }

  Future<void> _deleteStyle(PdfPreset style) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this style?'),
        content: w.Text(style.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(yes ?? false) || !mounted) return;
    setState(
      () => _mine = <PdfPreset>[
        for (final item in _mine)
          if (item.name != style.name) item,
      ],
    );
    widget.settings.storePdfStyles(encodeStyles(_mine));
  }

  Future<void> _pickColor(PdfOption option) async {
    final picked = await pickColor(
      context,
      initial: _options.color(option.key),
      allowNone: option.allowNone,
    );
    if (picked != null && mounted) _set(option.key, picked);
  }

  Widget _tile(PdfOption option) {
    switch (option.kind) {
      case OptionKind.toggle:
        return SwitchListTile(
          title: Text(option.label),
          value: _options.flag(option.key),
          onChanged: (value) => _set(option.key, value),
        );
      case OptionKind.choice:
        return ListTile(
          title: Text(option.label),
          trailing: DropdownButton<Object>(
            value: _options.value(option.key),
            underline: const SizedBox.shrink(),
            items: [
              for (final choice in option.choices)
                DropdownMenuItem<Object>(
                  value: choice.value,
                  child: Text(choice.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) _set(option.key, value);
            },
          ),
        );
      case OptionKind.number:
        return _NumberTile(
          option: option,
          value: _options.number(option.key),
          onChanged: (value) => _set(option.key, value),
        );
      case OptionKind.color:
        final value = _options.color(option.key);
        return ListTile(
          title: Text(option.label),
          trailing: _Swatch(argb: value),
          onTap: () => unawaited(_pickColor(option)),
        );
      case OptionKind.text:
        return _TextTile(
          option: option,
          value: _options.text(option.key),
          onChanged: (value) => _set(option.key, value),
        );
      case OptionKind.font:
        return ListTile(
          title: Text(option.label),
          subtitle: w.Text(FontLibrary.nameOf(_options.text(option.key))),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => unawaited(_pickFont(option)),
        );
    }
  }

  Widget _group(PdfGroup group, int index) {
    final visible = [
      for (final option in group.options)
        if (_options.visible(option)) option,
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: index == 0,
          leading: Icon(group.icon),
          title: Text(group.title),
          childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
          children: [
            if (group.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.xxs,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    group.note,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            for (final option in visible) _tile(option),
          ],
        ),
      ),
    );
  }

  Widget _settings(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.sm,
              children: [
                Text('Styles', style: theme.textTheme.titleSmall),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xxs,
                  children: [
                    for (final preset in PdfSchema.presets)
                      ChoiceChip(
                        label: Text(preset.name),
                        selected: _options.matches(preset),
                        onSelected: (_) => _preset(preset),
                      ),
                    for (final style in _mine)
                      InputChip(
                        label: w.Text(style.name),
                        selected: _options.matches(style),
                        onSelected: (_) => _preset(style),
                        onDeleted: () => unawaited(_deleteStyle(style)),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add_rounded),
                      label: const Text('Save as style'),
                      onPressed: () => unawaited(_saveStyle()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: w.Text(
              _error,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < PdfSchema.groups.length; i++) ...[
          _group(PdfSchema.groups[i], i),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  Widget _side(BuildContext context) {
    final result = _result;
    if (_busy) return const Center(child: CircularProgressIndicator());
    if (result == null) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.sm,
            children: [
              Icon(
                Icons.picture_as_pdf_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              Text(
                'Press Create PDF and the result will show here',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _ResultPane(
      key: ValueKey<String>('${result.path}#$_version'),
      result: result,
      name: _fileName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = Adaptive.twoPane(MediaQuery.sizeOf(context));
    return Scaffold(
      appBar: AppBar(title: const Text('Convert to PDF')),
      body: SafeArea(
        top: false,
        child: wide
            ? Row(
                children: [
                  Expanded(flex: 5, child: _settings(context)),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 4, child: _side(context)),
                ],
              )
            : _settings(context),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_create()),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_rounded),
            label: const Text('Create PDF'),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.argb});

  final int argb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final none = argb == 0;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: none ? null : Color(argb),
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: none
          ? Icon(
              Icons.block_rounded,
              size: 18,
              color: theme.colorScheme.outline,
            )
          : null,
    );
  }
}

class _NumberTile extends StatelessWidget {
  const _NumberTile({
    required this.option,
    required this.value,
    required this.onChanged,
  });

  final PdfOption option;
  final double value;
  final ValueChanged<double> onChanged;

  String _shown(double v) {
    var text = option.step >= 1
        ? v.round().toString()
        : v.toStringAsFixed(option.step < 0.1 ? 2 : 1);
    if (text.contains('.')) {
      text = text
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return option.unit.isEmpty ? text : '$text ${option.unit}';
  }

  double _snap(double v) {
    final steps = (v / option.step).round() * option.step;
    return double.parse(steps.toStringAsFixed(4));
  }

  Future<void> _type(BuildContext context) async {
    final controller = TextEditingController(
      text: _shown(value).split(' ').first,
    );
    final typed = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(option.label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          textDirection: TextDirection.ltr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(double.tryParse(controller.text.replaceAll(',', '.').trim())),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (typed != null) {
      onChanged(math.max(option.min, math.min(option.max, typed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divisions = ((option.max - option.min) / option.step).round();
    final shown = math.max(option.min, math.min(option.max, value));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: AppSpacing.xxs),
          Row(
            children: [
              Expanded(child: Text(option.label)),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.tile),
                onTap: () => unawaited(_type(context)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xxs,
                  ),
                  child: Text(
                    _shown(value),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Slider(
            value: shown,
            min: option.min,
            max: option.max,
            divisions: divisions > 0 && divisions <= 400 ? divisions : null,
            onChanged: (v) => onChanged(_snap(v)),
          ),
        ],
      ),
    );
  }
}

class _TextTile extends StatefulWidget {
  const _TextTile({
    required this.option,
    required this.value,
    required this.onChanged,
  });

  final PdfOption option;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TextTile> createState() => _TextTileState();
}

class _TextTileState extends State<_TextTile> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_TextTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxs,
      ),
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          labelText: widget.option.label.tr,
          hintText: widget.option.hint.isEmpty ? null : widget.option.hint.tr,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _ResultPane extends StatefulWidget {
  const _ResultPane({required this.result, required this.name, super.key});

  final PdfExportResult result;
  final String name;

  @override
  State<_ResultPane> createState() => _ResultPaneState();
}

class _ResultPaneState extends State<_ResultPane> {
  final PdfPagesController _controller = PdfPagesController();
  String _failure = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share() async {
    final done = await DocumentService.share(
      widget.result.path,
      'application/pdf',
    );
    if (!done && mounted) _say("Couldn't share this document");
  }

  Future<void> _save() async {
    final done = await DocumentService.saveDownload(
      widget.result.path,
      widget.name,
    );
    if (!done && mounted) _say("Couldn't save this file");
  }

  Future<void> _open() async {
    await DocumentOpener.keep(widget.result.path, widget.name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: _failure.isNotEmpty
              ? const Center(child: Text("Couldn't open this document"))
              : PdfPagesView(
                  path: widget.result.path,
                  initialPosition: 0,
                  invert: false,
                  controller: _controller,
                  onProgress: (position, progress) {},
                  onFailed: (reason) => setState(() => _failure = reason),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xxs,
            children: [
              if (widget.result.pages > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    '${widget.result.pages} pages',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_share()),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share'),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_save()),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Save to Downloads'),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_open()),
                icon: const Icon(Icons.library_add_outlined),
                label: const Text('Keep in my documents'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen({
    required this.result,
    required this.version,
    required this.name,
  });

  final PdfExportResult result;
  final int version;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: w.Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        top: false,
        child: _ResultPane(
          key: ValueKey<String>('${result.path}#$version'),
          result: result,
          name: name,
        ),
      ),
    );
  }
}
