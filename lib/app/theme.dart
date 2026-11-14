import 'package:flutter/material.dart';

import '../core/config/brand.dart';

/// 设计令牌（docs/02 §5）：seed 主色 + 状态色 + 圆角/触控目标。
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.seedColor,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// 状态色（docs/02 §5.1）。不单独依赖颜色，必须配合图标/文字（色盲友好）。
extension StatusColors on ColorScheme {
  Color get statusOnline => brightness == Brightness.light
      ? const Color(0xFF1E8E5A)
      : const Color(0xFF5FD39B);

  Color get statusWarning => brightness == Brightness.light
      ? const Color(0xFFB26A00)
      : const Color(0xFFFFC46B);

  Color get statusDanger => brightness == Brightness.light
      ? const Color(0xFFC62828)
      : const Color(0xFFFF8A80);

  Color get statusNeutral => brightness == Brightness.light
      ? const Color(0xFF5F6368)
      : const Color(0xFFC4C7C5);
}
