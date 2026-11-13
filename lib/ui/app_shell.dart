import 'dart:async';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/localization/localization.dart';
import 'package:flutter/services.dart';
import 'package:olako/app_info.dart';
import 'package:olako/core/library_index.dart';
import 'package:olako/core/recent_store.dart';
import 'package:olako/settings/app_settings.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/document_opener.dart';
import 'package:olako/ui/home_screen.dart';
import 'package:olako/ui/settings_screen.dart';
import 'package:olako/ui/update_prompt.dart';
import 'package:olako/ui/widgets/adaptive.dart';

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class AppShell extends StatefulWidget {
  const AppShell({required this.settings, required this.recents, super.key});

  final AppSettings settings;
  final RecentStore recents;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const double _sidebarBreakpoint = 800;
  static const _destinations = [
    _Destination('Home', Icons.home_outlined, Icons.home_rounded),
    _Destination('Settings', Icons.tune_rounded, Icons.tune_rounded),
  ];

  static var _lastIndex = 0;

  var _index = _lastIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(DocumentOpener.start(widget.recents, widget.settings));
      unawaited(LibraryIndex.instance.start());
      UpdatePrompt.run(context, widget.settings);
    });
  }

  void _select(int index) => setState(() => _index = _lastIndex = index);

  @override
  Widget build(BuildContext context) {
    final page = SafeArea(
      child: switch (_index) {
        0 => HomeScreen(recents: widget.recents),
        _ => SettingsScreen(settings: widget.settings),
      },
    );

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final overlayStyle =
        (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: theme.colorScheme.surfaceContainerLow,
              systemNavigationBarIconBrightness: isDark
                  ? Brightness.light
                  : Brightness.dark,
            );

    final Widget scaffold;
    if (MediaQuery.sizeOf(context).width >= _sidebarBreakpoint) {
      scaffold = Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              destinations: _destinations,
              selectedIndex: _index,
              onSelected: _select,
            ),
            Expanded(child: page),
          ],
        ),
      );
    } else if (Adaptive.shortLandscape(MediaQuery.sizeOf(context))) {
      scaffold = Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(
              destinations: _destinations,
              selectedIndex: _index,
              onSelected: _select,
            ),
            Expanded(child: page),
          ],
        ),
      );
    } else {
      scaffold = Scaffold(
        body: page,
        bottomNavigationBar: _CompactBar(
          destinations: _destinations,
          selectedIndex: _index,
          onSelected: _select,
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: scaffold,
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _width = 11 * AppSpacing.spaceUnit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        width: _width,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.xxs,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                  child: Center(
                    child: Text(
                      AppInfo.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < destinations.length; i++)
                  ListTile(
                    selected: i == selectedIndex,
                    leading: Icon(
                      i == selectedIndex
                          ? destinations[i].selectedIcon
                          : destinations[i].icon,
                    ),
                    title: Text(destinations[i].label),
                    onTap: () => onSelected(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: SizedBox(
          width: 148,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < destinations.length; i++)
                _CompactItem(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _height,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < destinations.length; i++)
                _CompactItem(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactItem extends StatelessWidget {
  const _CompactItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  static const double _pillHeight = 40;
  static const Duration _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label.tr,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: onTap,
            child: AnimatedContainer(
              duration: _duration,
              curve: Curves.easeOutCubic,
              height: _pillHeight,
              constraints: const BoxConstraints(minWidth: 48),
              padding: EdgeInsets.symmetric(
                horizontal: selected ? AppSpacing.md : AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: AnimatedSize(
                duration: _duration,
                curve: Curves.easeOutCubic,
                alignment: AlignmentDirectional.centerStart,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: AppSpacing.sm,
                  children: [
                    Icon(
                      selected ? destination.selectedIcon : destination.icon,
                      color: color,
                    ),
                    if (selected)
                      Text(
                        destination.label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: color,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
