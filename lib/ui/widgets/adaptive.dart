import 'package:flutter/material.dart';
import 'package:olako/theme/app_spacing.dart';

abstract class Adaptive {
  static int columns(double width, {double minTile = 340}) {
    final count = (width / minTile).floor();
    if (count < 1) return 1;
    return count > 3 ? 3 : count;
  }

  static bool shortLandscape(Size size) =>
      size.width > size.height && size.height < 480;

  static bool twoPane(Size size) =>
      (size.width >= 840 && size.height >= 480) ||
      (size.width >= 640 && shortLandscape(size));
}

class TileRow extends StatelessWidget {
  const TileRow({required this.columns, required this.items, super.key});

  final int columns;
  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return Column(children: items);
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.md,
        children: [
          for (var i = 0; i < columns; i++)
            Expanded(
              child: i < items.length ? items[i] : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}

List<Widget> tileRows(int columns, List<Widget> tiles) {
  if (columns <= 1) return tiles;
  return <Widget>[
    for (var i = 0; i < tiles.length; i += columns)
      TileRow(
        columns: columns,
        items: tiles.sublist(
          i,
          i + columns > tiles.length ? tiles.length : i + columns,
        ),
      ),
  ];
}
