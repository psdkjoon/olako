import 'package:flutter/material.dart';
import 'package:olako/theme/app_spacing.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({
    required this.child,
    this.actions = const [],
    this.width = maxWidth,
    super.key,
  });

  final Widget child;
  final List<Widget> actions;
  final double width;

  static const double maxWidth = 36 * AppSpacing.spaceUnit;

  static double gutter(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 400 ? AppSpacing.md : AppSpacing.xl;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: EdgeInsets.only(
            left: gutter(context),
            right: gutter(context),
            top: gutter(context),
          ),
          child: Column(
            spacing: AppSpacing.md,
            children: [
              if (actions.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
