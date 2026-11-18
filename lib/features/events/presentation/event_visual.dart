import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

/// 事件类型 → 图标/颜色/文案 的统一映射（列表、横幅、详情共用）。
(IconData, Color, String) eventVisual(
  BuildContext context,
  AppLocalizations l10n,
  String type,
) {
  final theme = Theme.of(context);
  return switch (type) {
    'deviceOnline' => (
        Icons.wifi,
        theme.colorScheme.statusOnline,
        l10n.eventTypeDeviceOnline
      ),
    'deviceOffline' => (
        Icons.wifi_off,
        theme.colorScheme.statusNeutral,
        l10n.eventTypeDeviceOffline
      ),
    'geofenceEnter' => (
        Icons.login,
        theme.colorScheme.primary,
        l10n.eventTypeGeofenceEnter
      ),
    'geofenceExit' => (
        Icons.logout,
        theme.colorScheme.primary,
        l10n.eventTypeGeofenceExit
      ),
    'alarm' => (
        Icons.warning_amber,
        theme.colorScheme.statusDanger,
        l10n.eventTypeAlarm
      ),
    'sos' => (
        Icons.emergency,
        theme.colorScheme.statusDanger,
        l10n.eventTypeSos
      ),
    'overspeed' || 'deviceOverspeed' => (
        Icons.speed,
        theme.colorScheme.statusWarning,
        l10n.eventTypeOverspeed
      ),
    'maintenance' => (
        Icons.build,
        theme.colorScheme.statusWarning,
        l10n.eventTypeMaintenance
      ),
    'ignitionOn' => (
        Icons.key,
        theme.colorScheme.primary,
        l10n.eventTypeIgnitionOn
      ),
    'ignitionOff' => (
        Icons.key_off,
        theme.colorScheme.primary,
        l10n.eventTypeIgnitionOff
      ),
    _ => (
        Icons.info_outline,
        theme.colorScheme.statusNeutral,
        l10n.eventTypeUnknown
      ),
  };
}
