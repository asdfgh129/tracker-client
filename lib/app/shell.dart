import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/settings/application/settings_controller.dart';
import '../l10n/app_localizations.dart';

/// 底部导航骨架（docs/02 §1：按模式动态）。
///
/// 分支索引与 router 中 StatefulShellRoute 固定顺序一致：
/// map=0, devices=1, friends=2, events=3, tracking=4, settings=5。
/// 「跟踪本机」模式隐藏前四个；「查看设备」隐藏 tracking。
class AppShell extends ConsumerWidget {
  const AppShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  static const _allSpecs = <_TabSpec>[
    _TabSpec('/map', 0, Icons.map_outlined, Icons.map),
    _TabSpec('/devices', 1, Icons.devices_other_outlined, Icons.devices_other),
    _TabSpec('/friends', 2, Icons.group_outlined, Icons.group),
    _TabSpec('/events', 3, Icons.notifications_outlined, Icons.notifications),
    _TabSpec('/tracking', 4, Icons.my_location_outlined, Icons.my_location),
    _TabSpec('/settings', 5, Icons.person_outline, Icons.person),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    final l10n = AppLocalizations.of(context);

    final labels = {
      '/map': l10n.tabMap,
      '/devices': l10n.tabDevices,
      '/friends': l10n.tabFriends,
      '/events': l10n.tabEvents,
      '/tracking': l10n.tabTracking,
      '/settings': l10n.tabSettings,
    };

    final destinations = _allSpecs
        .where((spec) => switch (spec.path) {
              '/map' || '/devices' || '/events' || '/friends' =>
                mode != UsageMode.track,
              '/tracking' => mode != UsageMode.view,
              _ => true,
            })
        .toList(growable: false);

    final location = GoRouterState.of(context).uri.path;
    final selectedIndex = destinations.indexWhere(
      (spec) => location.startsWith(spec.path),
    );

    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onDestinationSelected: (index) {
          final spec = destinations[index];
          shell.goBranch(spec.branchIndex, initialLocation: false);
        },
        destinations: [
          for (final spec in destinations)
            NavigationDestination(
              icon: Icon(spec.outlined),
              selectedIcon: Icon(spec.filled),
              label: labels[spec.path] ?? spec.path,
              tooltip: labels[spec.path] ?? spec.path,
            ),
        ],
      ),
    );
  }
}

class _TabSpec {
  const _TabSpec(this.path, this.branchIndex, this.outlined, this.filled);

  final String path;
  final int branchIndex;
  final IconData outlined;
  final IconData filled;
}
