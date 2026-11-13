import 'dart:convert';

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:olako/localization/localization.dart';

enum OptionKind { toggle, choice, number, color, text, font }

class Choice {
  const Choice(this.value, this.label);

  final Object value;
  final String label;
}

class PdfOption {
  const PdfOption(
    this.key,
    this.label,
    this.kind,
    this.fallback, {
    this.choices = const <Choice>[],
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.unit = '',
    this.allowNone = false,
    this.same = false,
    this.onlyIf,
    this.hint = '',
  });

  final String key;
  final String label;
  final OptionKind kind;
  final Object fallback;
  final List<Choice> choices;
  final double min;
  final double max;
  final double step;
  final String unit;
  final bool allowNone;
  final bool same;
  final (String, Object)? onlyIf;
  final String hint;
}

class PdfGroup {
  const PdfGroup(this.title, this.icon, this.options, {this.note = ''});

  final String title;
  final IconData icon;
  final List<PdfOption> options;
  final String note;
}

class PdfPreset {
  const PdfPreset(this.name, this.values);

  final String name;
  final Map<String, Object> values;
}

const _levelChoices = <Choice>[
  Choice(0, 'Off'),
  Choice(1, 'Heading 1'),
  Choice(2, 'Up to heading 2'),
  Choice(3, 'Up to heading 3'),
];

abstract class PdfSchema {
  static const List<PdfGroup> groups = <PdfGroup>[
    PdfGroup('Page', Icons.crop_portrait_rounded, <PdfOption>[
      PdfOption(
        'pageSize',
        'Page size',
        OptionKind.choice,
        'a4',
        choices: <Choice>[
          Choice('a4', 'A4'),
          Choice('a5', 'A5'),
          Choice('a3', 'A3'),
          Choice('a6', 'A6'),
          Choice('b5', 'B5'),
          Choice('letter', 'Letter'),
          Choice('legal', 'Legal'),
          Choice('custom', 'Custom'),
        ],
      ),
      PdfOption(
        'customW',
        'Page width',
        OptionKind.number,
        210,
        min: 50,
        max: 600,
        unit: 'mm',
        onlyIf: ('pageSize', 'custom'),
      ),
      PdfOption(
        'customH',
        'Page height',
        OptionKind.number,
        297,
        min: 50,
        max: 900,
        unit: 'mm',
        onlyIf: ('pageSize', 'custom'),
      ),
      PdfOption(
        'orientation',
        'Orientation',
        OptionKind.choice,
        'portrait',
        choices: <Choice>[
          Choice('portrait', 'Portrait'),
          Choice('landscape', 'Landscape'),
        ],
      ),
      PdfOption('pageColor', 'Page color', OptionKind.color, 0xFFFFFFFF),
    ]),
    PdfGroup('Margins', Icons.padding_rounded, <PdfOption>[
      PdfOption('marginTop', 'Top', OptionKind.number, 22, max: 80, unit: 'mm'),
      PdfOption(
        'marginBottom',
        'Bottom',
        OptionKind.number,
        22,
        max: 80,
        unit: 'mm',
      ),
      PdfOption(
        'marginInner',
        'Inner (binding side)',
        OptionKind.number,
        22,
        max: 80,
        unit: 'mm',
      ),
      PdfOption(
        'marginOuter',
        'Outer',
        OptionKind.number,
        18,
        max: 80,
        unit: 'mm',
      ),
      PdfOption('mirror', 'Swap sides on even pages', OptionKind.toggle, false),
    ]),
    PdfGroup('Page border', Icons.border_style_rounded, <PdfOption>[
      PdfOption('border', 'Draw a border', OptionKind.toggle, false),
      PdfOption(
        'borderStyle',
        'Border style',
        OptionKind.choice,
        'solid',
        choices: <Choice>[
          Choice('solid', 'Solid'),
          Choice('dashed', 'Dashed'),
          Choice('double', 'Double'),
        ],
        onlyIf: ('border', true),
      ),
      PdfOption(
        'borderColor',
        'Border color',
        OptionKind.color,
        0xFF444444,
        onlyIf: ('border', true),
      ),
      PdfOption(
        'borderWidth',
        'Border width',
        OptionKind.number,
        1,
        min: 0.3,
        max: 6,
        step: 0.1,
        unit: 'pt',
        onlyIf: ('border', true),
      ),
      PdfOption(
        'borderInset',
        'Distance from the edge',
        OptionKind.number,
        8,
        min: 2,
        max: 40,
        unit: 'mm',
        onlyIf: ('border', true),
      ),
    ]),
    PdfGroup('Text', Icons.text_fields_rounded, <PdfOption>[
      PdfOption('font', 'Font', OptionKind.font, 'sans'),
      PdfOption(
        'fontSize',
        'Font size',
        OptionKind.number,
        11,
        min: 6,
        max: 30,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'lineHeight',
        'Line height',
        OptionKind.number,
        1.45,
        min: 1,
        max: 2.5,
        step: 0.05,
      ),
      PdfOption(
        'paragraphSpacing',
        'Space between paragraphs',
        OptionKind.number,
        8,
        max: 40,
        unit: 'pt',
      ),
      PdfOption(
        'align',
        'Alignment',
        OptionKind.choice,
        'start',
        choices: <Choice>[
          Choice('start', 'Start'),
          Choice('justify', 'Justified'),
          Choice('center', 'Centered'),
          Choice('end', 'End'),
        ],
      ),
      PdfOption('hyphenate', 'Hyphenate words', OptionKind.toggle, false),
      PdfOption(
        'direction',
        'Text direction',
        OptionKind.choice,
        'auto',
        choices: <Choice>[
          Choice('auto', 'Automatic'),
          Choice('ltr', 'Left to right'),
          Choice('rtl', 'Right to left'),
        ],
      ),
      PdfOption(
        'digits',
        'Digits in page numbers',
        OptionKind.choice,
        'latin',
        choices: <Choice>[
          Choice('latin', 'Latin'),
          Choice('persian', 'Persian'),
        ],
      ),
      PdfOption('textColor', 'Text color', OptionKind.color, 0xFF1B1B1F),
      PdfOption('linkColor', 'Link color', OptionKind.color, 0xFF1A5FB4),
      PdfOption('linkUnderline', 'Underline links', OptionKind.toggle, true),
    ]),
    PdfGroup('Headings', Icons.title_rounded, <PdfOption>[
      PdfOption(
        'headingFont',
        'Heading font',
        OptionKind.font,
        'same',
        same: true,
      ),
      PdfOption('headingColor', 'Heading color', OptionKind.color, 0xFF111111),
      PdfOption('headingBold', 'Bold headings', OptionKind.toggle, true),
      PdfOption(
        'h1Size',
        'Heading 1 size',
        OptionKind.number,
        26,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'h2Size',
        'Heading 2 size',
        OptionKind.number,
        20,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'h3Size',
        'Heading 3 size',
        OptionKind.number,
        16,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'h4Size',
        'Heading 4 size',
        OptionKind.number,
        13.5,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'h5Size',
        'Heading 5 size',
        OptionKind.number,
        12,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'h6Size',
        'Heading 6 size',
        OptionKind.number,
        11,
        min: 8,
        max: 60,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'headingAlign',
        'Heading alignment',
        OptionKind.choice,
        'start',
        choices: <Choice>[
          Choice('start', 'Start'),
          Choice('center', 'Centered'),
          Choice('end', 'End'),
          Choice('same', 'Same as text'),
        ],
      ),
      PdfOption(
        'headingBefore',
        'Space above',
        OptionKind.number,
        18,
        max: 60,
        unit: 'pt',
      ),
      PdfOption(
        'headingAfter',
        'Space below',
        OptionKind.number,
        8,
        max: 40,
        unit: 'pt',
      ),
      PdfOption(
        'numberHeadings',
        'Number the headings',
        OptionKind.toggle,
        false,
      ),
      PdfOption(
        'headingRuleLevel',
        'Line under headings',
        OptionKind.choice,
        0,
        choices: _levelChoices,
      ),
    ]),
    PdfGroup(
      'Page breaks',
      Icons.content_cut_rounded,
      <PdfOption>[
        PdfOption(
          'breakLevel',
          'New page before headings',
          OptionKind.choice,
          0,
          choices: _levelChoices,
        ),
        PdfOption(
          'keepHeadingWithNext',
          'Keep a heading with its text',
          OptionKind.toggle,
          true,
        ),
        PdfOption(
          'minLines',
          'Lines kept together at a page edge',
          OptionKind.number,
          2,
          min: 1,
          max: 5,
        ),
        PdfOption(
          'keepCodeTogether',
          'Keep code blocks on one page',
          OptionKind.toggle,
          false,
        ),
        PdfOption(
          'repeatTableHeader',
          'Repeat table header on each page',
          OptionKind.toggle,
          true,
        ),
        PdfOption(
          'ruleAction',
          'Horizontal rules',
          OptionKind.choice,
          'line',
          choices: <Choice>[
            Choice('line', 'Draw a line'),
            Choice('pagebreak', 'Start a new page'),
            Choice('ignore', 'Skip them'),
          ],
        ),
        PdfOption('ruleColor', 'Line color', OptionKind.color, 0xFFC9CCD1),
        PdfOption(
          'ruleThickness',
          'Line thickness',
          OptionKind.number,
          0.8,
          min: 0.2,
          max: 4,
          step: 0.1,
          unit: 'pt',
        ),
      ],
      note: 'Put <!-- pagebreak --> on its own line to cut the page anywhere.',
    ),
    PdfGroup(
      'Lists and quotes',
      Icons.format_list_bulleted_rounded,
      <PdfOption>[
        PdfOption(
          'listIndent',
          'List indent',
          OptionKind.number,
          20,
          min: 8,
          max: 60,
          unit: 'pt',
        ),
        PdfOption(
          'listSpacing',
          'Space between items',
          OptionKind.number,
          3,
          max: 20,
          unit: 'pt',
        ),
        PdfOption(
          'quoteColor',
          'Quote text color',
          OptionKind.color,
          0,
          allowNone: true,
        ),
        PdfOption(
          'quoteBarColor',
          'Quote bar color',
          OptionKind.color,
          0xFF9AA0A6,
        ),
        PdfOption('quoteItalic', 'Italic quotes', OptionKind.toggle, false),
        PdfOption(
          'quoteIndent',
          'Quote indent',
          OptionKind.number,
          12,
          min: 4,
          max: 40,
          unit: 'pt',
        ),
      ],
    ),
    PdfGroup('Code', Icons.code_rounded, <PdfOption>[
      PdfOption('codeFont', 'Code font', OptionKind.font, 'mono'),
      PdfOption(
        'codeSize',
        'Code size',
        OptionKind.number,
        9.5,
        min: 6,
        max: 24,
        step: 0.5,
        unit: 'pt',
      ),
      PdfOption(
        'codeLineHeight',
        'Code line height',
        OptionKind.number,
        1.3,
        min: 1,
        max: 2,
        step: 0.05,
      ),
      PdfOption(
        'codePadding',
        'Code padding',
        OptionKind.number,
        8,
        max: 30,
        unit: 'pt',
      ),
      PdfOption(
        'codeRadius',
        'Corner roundness',
        OptionKind.number,
        4,
        max: 20,
        unit: 'pt',
      ),
      PdfOption('codeColor', 'Code color', OptionKind.color, 0xFF24292F),
      PdfOption(
        'codeBackground',
        'Code background',
        OptionKind.color,
        0xFFF1F3F5,
        allowNone: true,
      ),
      PdfOption(
        'inlineCodeColor',
        'Inline code color',
        OptionKind.color,
        0,
        allowNone: true,
      ),
      PdfOption(
        'inlineCodeBackground',
        'Inline code background',
        OptionKind.color,
        0xFFEFF1F3,
        allowNone: true,
      ),
    ]),
    PdfGroup('Tables', Icons.table_chart_outlined, <PdfOption>[
      PdfOption(
        'tableBorder',
        'Table lines',
        OptionKind.choice,
        'grid',
        choices: <Choice>[
          Choice('grid', 'Grid'),
          Choice('rows', 'Row lines'),
          Choice('none', 'None'),
        ],
      ),
      PdfOption('tableBorderColor', 'Line color', OptionKind.color, 0xFFB8BDC4),
      PdfOption(
        'tableBorderWidth',
        'Line width',
        OptionKind.number,
        0.6,
        min: 0.2,
        max: 3,
        step: 0.1,
        unit: 'pt',
      ),
      PdfOption(
        'tableHeaderBackground',
        'Header background',
        OptionKind.color,
        0xFFE9ECEF,
        allowNone: true,
      ),
      PdfOption(
        'tableHeaderColor',
        'Header text color',
        OptionKind.color,
        0xFF111111,
      ),
      PdfOption('tableZebra', 'Shade every other row', OptionKind.toggle, true),
      PdfOption(
        'tableZebraColor',
        'Shade color',
        OptionKind.color,
        0xFFF6F7F8,
        onlyIf: ('tableZebra', true),
      ),
      PdfOption(
        'tablePadding',
        'Cell padding',
        OptionKind.number,
        5,
        min: 1,
        max: 16,
        unit: 'pt',
      ),
      PdfOption(
        'tableFontScale',
        'Table text scale',
        OptionKind.number,
        0.92,
        min: 0.6,
        max: 1.3,
        step: 0.02,
      ),
    ]),
    PdfGroup('Images', Icons.image_outlined, <PdfOption>[
      PdfOption(
        'imageWidth',
        'Widest an image can be',
        OptionKind.number,
        100,
        min: 10,
        max: 100,
        step: 5,
        unit: '%',
      ),
      PdfOption(
        'imageAlign',
        'Image position',
        OptionKind.choice,
        'center',
        choices: <Choice>[
          Choice('center', 'Centered'),
          Choice('start', 'Start'),
        ],
      ),
      PdfOption('imageFill', 'Enlarge small images', OptionKind.toggle, false),
      PdfOption(
        'imageCaptions',
        'Show descriptions under images',
        OptionKind.toggle,
        false,
      ),
    ]),
    PdfGroup('Cover page', Icons.menu_book_rounded, <PdfOption>[
      PdfOption('cover', 'Add a cover page', OptionKind.toggle, false),
      PdfOption(
        'coverTitle',
        'Title',
        OptionKind.text,
        '',
        onlyIf: ('cover', true),
        hint: 'Document name',
      ),
      PdfOption(
        'coverSubtitle',
        'Subtitle',
        OptionKind.text,
        '',
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverAuthor',
        'Author',
        OptionKind.text,
        '',
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverDate',
        'Show the date',
        OptionKind.toggle,
        false,
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverAlign',
        'Alignment',
        OptionKind.choice,
        'center',
        choices: <Choice>[
          Choice('start', 'Start'),
          Choice('center', 'Centered'),
          Choice('end', 'End'),
        ],
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverTitleSize',
        'Title size',
        OptionKind.number,
        34,
        min: 14,
        max: 80,
        unit: 'pt',
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverSubtitleSize',
        'Subtitle size',
        OptionKind.number,
        16,
        min: 8,
        max: 40,
        unit: 'pt',
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverPosition',
        'Height on the page',
        OptionKind.number,
        38,
        min: 10,
        max: 90,
        unit: '%',
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverColor',
        'Text color',
        OptionKind.color,
        0xFF111111,
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverBackground',
        'Background color',
        OptionKind.color,
        0,
        allowNone: true,
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'coverRule',
        'Accent line under the title',
        OptionKind.toggle,
        true,
        onlyIf: ('cover', true),
      ),
      PdfOption(
        'accentColor',
        'Accent color',
        OptionKind.color,
        0xFF1A5FB4,
        onlyIf: ('cover', true),
      ),
    ]),
    PdfGroup('Contents', Icons.list_alt_rounded, <PdfOption>[
      PdfOption('toc', 'Add a table of contents', OptionKind.toggle, false),
      PdfOption(
        'tocTitle',
        'Title',
        OptionKind.text,
        'Contents',
        onlyIf: ('toc', true),
      ),
      PdfOption(
        'tocDepth',
        'Deepest heading level',
        OptionKind.number,
        3,
        min: 1,
        max: 6,
        onlyIf: ('toc', true),
      ),
      PdfOption(
        'tocLeader',
        'Dotted lines to page numbers',
        OptionKind.toggle,
        true,
        onlyIf: ('toc', true),
      ),
      PdfOption(
        'tocSize',
        'Text size',
        OptionKind.number,
        11,
        min: 7,
        max: 20,
        step: 0.5,
        unit: 'pt',
        onlyIf: ('toc', true),
      ),
    ]),
    PdfGroup(
      'Header and footer',
      Icons.vertical_align_top_rounded,
      <PdfOption>[
        PdfOption('headerLeft', 'Header, left', OptionKind.text, ''),
        PdfOption('headerCenter', 'Header, center', OptionKind.text, ''),
        PdfOption('headerRight', 'Header, right', OptionKind.text, ''),
        PdfOption('footerLeft', 'Footer, left', OptionKind.text, ''),
        PdfOption('footerCenter', 'Footer, center', OptionKind.text, '{page}'),
        PdfOption('footerRight', 'Footer, right', OptionKind.text, ''),
        PdfOption(
          'bandSize',
          'Text size',
          OptionKind.number,
          9,
          min: 6,
          max: 16,
          step: 0.5,
          unit: 'pt',
        ),
        PdfOption('bandColor', 'Text color', OptionKind.color, 0xFF666A70),
        PdfOption(
          'headerRule',
          'Line under the header',
          OptionKind.toggle,
          false,
        ),
        PdfOption(
          'footerRule',
          'Line above the footer',
          OptionKind.toggle,
          false,
        ),
        PdfOption(
          'headerDistance',
          'Header distance from the top',
          OptionKind.number,
          10,
          min: 3,
          max: 40,
          unit: 'mm',
        ),
        PdfOption(
          'footerDistance',
          'Footer distance from the bottom',
          OptionKind.number,
          10,
          min: 3,
          max: 40,
          unit: 'mm',
        ),
        PdfOption(
          'pageNumberFormat',
          'Page number style',
          OptionKind.choice,
          'arabic',
          choices: <Choice>[
            Choice('arabic', 'Numbers'),
            Choice('roman', 'Small roman'),
            Choice('romanUpper', 'Capital roman'),
            Choice('alpha', 'Letters'),
          ],
        ),
        PdfOption(
          'startPage',
          'First page number',
          OptionKind.number,
          1,
          min: 1,
          max: 999,
        ),
        PdfOption(
          'skipFirstPage',
          'Hide on the first page',
          OptionKind.toggle,
          false,
        ),
        PdfOption(
          'sectionLevel',
          'Heading level used for the section',
          OptionKind.number,
          1,
          min: 1,
          max: 3,
        ),
      ],
      note: 'Use {page}, {pages}, {title}, {date} and {section} in the boxes.',
    ),
    PdfGroup('Watermark', Icons.water_drop_outlined, <PdfOption>[
      PdfOption('watermark', 'Watermark text', OptionKind.text, ''),
      PdfOption(
        'watermarkColor',
        'Color',
        OptionKind.color,
        0xFF888888,
        onlyIf: ('watermark', ''),
      ),
      PdfOption(
        'watermarkOpacity',
        'Strength',
        OptionKind.number,
        15,
        min: 2,
        max: 100,
        unit: '%',
      ),
      PdfOption(
        'watermarkSize',
        'Size',
        OptionKind.number,
        72,
        min: 20,
        max: 220,
        unit: 'pt',
      ),
      PdfOption(
        'watermarkAngle',
        'Tilt',
        OptionKind.number,
        45,
        min: -90,
        max: 90,
        unit: '°',
      ),
    ]),
  ];

  static final Map<String, PdfOption> byKey = <String, PdfOption>{
    for (final group in groups)
      for (final option in group.options) option.key: option,
  };

  static final Map<String, Object> defaults = <String, Object>{
    for (final option in byKey.values) option.key: option.fallback,
  };

  static const List<PdfPreset> presets = <PdfPreset>[
    PdfPreset('Clean', <String, Object>{}),
    PdfPreset('Academic', <String, Object>{
      'font': 'serif',
      'fontSize': 12,
      'lineHeight': 1.5,
      'align': 'justify',
      'hyphenate': true,
      'headingFont': 'serif',
      'numberHeadings': true,
      'h1Size': 22,
      'h2Size': 17,
      'h3Size': 14,
      'h4Size': 12.5,
      'h5Size': 12,
      'h6Size': 12,
      'headingColor': 0xFF000000,
      'textColor': 0xFF000000,
      'marginInner': 30,
      'marginOuter': 25,
    }),
    PdfPreset('Report', <String, Object>{
      'cover': true,
      'toc': true,
      'numberHeadings': true,
      'breakLevel': 1,
      'headingRuleLevel': 1,
      'headerRight': '{section}',
      'headerRule': true,
      'footerLeft': '{title}',
      'footerCenter': '',
      'footerRight': '{page} / {pages}',
      'footerRule': true,
      'skipFirstPage': true,
    }),
    PdfPreset('Book', <String, Object>{
      'pageSize': 'a5',
      'font': 'serif',
      'headingFont': 'serif',
      'fontSize': 11,
      'lineHeight': 1.5,
      'paragraphSpacing': 5,
      'align': 'justify',
      'hyphenate': true,
      'mirror': true,
      'marginTop': 20,
      'marginBottom': 22,
      'marginInner': 24,
      'marginOuter': 16,
      'breakLevel': 1,
      'h1Size': 24,
      'h2Size': 18,
      'h3Size': 14,
      'h4Size': 12,
    }),
    PdfPreset('Compact', <String, Object>{
      'fontSize': 9.5,
      'lineHeight': 1.3,
      'paragraphSpacing': 5,
      'marginTop': 14,
      'marginBottom': 14,
      'marginInner': 16,
      'marginOuter': 12,
      'h1Size': 20,
      'h2Size': 16,
      'h3Size': 13,
      'h4Size': 11.5,
      'h5Size': 10.5,
      'h6Size': 9.5,
      'headingBefore': 12,
      'headingAfter': 5,
      'codeSize': 8.5,
      'tablePadding': 3,
    }),
    PdfPreset('Dark', <String, Object>{
      'pageColor': 0xFF1E1E2E,
      'textColor': 0xFFCDD6F4,
      'headingColor': 0xFFF5E0DC,
      'linkColor': 0xFF89B4FA,
      'ruleColor': 0xFF585B70,
      'codeColor': 0xFFCDD6F4,
      'codeBackground': 0xFF313244,
      'inlineCodeBackground': 0xFF313244,
      'quoteBarColor': 0xFF6C7086,
      'tableBorderColor': 0xFF585B70,
      'tableHeaderBackground': 0xFF313244,
      'tableHeaderColor': 0xFFCDD6F4,
      'tableZebraColor': 0xFF262637,
      'bandColor': 0xFFA6ADC8,
      'coverColor': 0xFFF5E0DC,
      'accentColor': 0xFF89B4FA,
      'borderColor': 0xFF6C7086,
    }),
  ];
}

class PdfOptions {
  PdfOptions._(this._values);

  factory PdfOptions.fresh() {
    final values = Map<String, Object>.of(PdfSchema.defaults);
    if (L10n.code == 'fa') values['digits'] = 'persian';
    return PdfOptions._(values);
  }

  factory PdfOptions.fromJson(String? json) {
    final options = PdfOptions.fresh();
    if (json == null || json.isEmpty) return options;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return options;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final option = key is String ? PdfSchema.byKey[key] : null;
        if (option == null) continue;
        final value = _clean(option, entry.value);
        if (value != null) options._values[option.key] = value;
      }
    } on FormatException {
      return options;
    }
    return options;
  }

  final Map<String, Object> _values;

  static Object? _clean(PdfOption option, Object? raw) {
    switch (option.kind) {
      case OptionKind.toggle:
        return raw is bool ? raw : null;
      case OptionKind.choice:
        for (final choice in option.choices) {
          if (choice.value == raw) return choice.value;
        }
        return null;
      case OptionKind.number:
        if (raw is! num) return null;
        final low = option.min < option.max ? option.min : option.max;
        final high = option.min < option.max ? option.max : option.min;
        final v = raw.toDouble();
        return v < low ? low : (v > high ? high : v);
      case OptionKind.color:
        return raw is num ? raw.toInt() : null;
      case OptionKind.text:
        return raw is String ? raw : null;
      case OptionKind.font:
        if (raw is! String) return null;
        if (raw == 'sans' || raw == 'serif' || raw == 'mono') return raw;
        if (raw == 'same' && option.same) return raw;
        return raw.startsWith('dir:') ? raw : null;
    }
  }

  Object value(String key) => _values[key] ?? PdfSchema.defaults[key]!;

  bool flag(String key) => value(key) == true;

  String text(String key) {
    final v = value(key);
    return v is String ? v : '';
  }

  double number(String key) {
    final v = value(key);
    return v is num ? v.toDouble() : 0;
  }

  int color(String key) {
    final v = value(key);
    return v is num ? v.toInt() : 0;
  }

  void set(String key, Object next) {
    final option = PdfSchema.byKey[key];
    if (option == null) return;
    final cleaned = _clean(option, next);
    if (cleaned != null) _values[key] = cleaned;
  }

  void applyPreset(PdfPreset preset) {
    final keep = <String, Object>{
      for (final key in <String>{'digits', ..._personal})
        if (_values[key] != null) key: _values[key]!,
    };
    _values
      ..clear()
      ..addAll(PdfSchema.defaults)
      ..addAll(keep);
    for (final entry in preset.values.entries) {
      set(entry.key, entry.value);
    }
  }

  bool visible(PdfOption option) {
    final rule = option.onlyIf;
    if (rule == null) return true;
    final current = value(rule.$1);
    if (rule.$2 is String && rule.$2 == '') {
      return current is String && current.isNotEmpty;
    }
    return current == rule.$2;
  }

  static const Set<String> _personal = <String>{
    'coverTitle',
    'coverSubtitle',
    'coverAuthor',
  };

  Map<String, Object> changed() {
    final out = <String, Object>{};
    for (final entry in _values.entries) {
      if (entry.value != PdfSchema.defaults[entry.key]) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  Map<String, Object> styleValues() {
    final out = changed();
    for (final key in _personal) {
      out.remove(key);
    }
    return out;
  }

  bool matches(PdfPreset preset) {
    final expected = Map<String, Object>.of(PdfSchema.defaults);
    for (final entry in preset.values.entries) {
      final option = PdfSchema.byKey[entry.key];
      if (option == null) continue;
      final cleaned = _clean(option, entry.value);
      if (cleaned != null) expected[entry.key] = cleaned;
    }
    for (final entry in expected.entries) {
      if (entry.key == 'digits' || _personal.contains(entry.key)) continue;
      if (_values[entry.key] != entry.value) return false;
    }
    return true;
  }

  String toJson() => jsonEncode(changed());

  Map<String, Object> toExport() {
    final out = Map<String, Object>.of(_values);
    final contents = out['tocTitle'];
    if (contents is String) out['tocTitle'] = contents.tr;
    return out;
  }
}

List<PdfPreset> parseStyles(String json) {
  if (json.isEmpty) return <PdfPreset>[];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return <PdfPreset>[];
    final out = <PdfPreset>[];
    for (final entry in decoded.entries) {
      final name = entry.key;
      final values = entry.value;
      if (name is! String || values is! Map) continue;
      final clean = <String, Object>{};
      for (final item in values.entries) {
        final key = item.key;
        final value = item.value;
        if (key is String && value != null) clean[key] = value as Object;
      }
      out.add(PdfPreset(name, clean));
    }
    return out;
  } on FormatException {
    return <PdfPreset>[];
  }
}

String encodeStyles(List<PdfPreset> styles) {
  return jsonEncode(<String, Object>{
    for (final style in styles) style.name: style.values,
  });
}
