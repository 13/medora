/// Medora - App Theme Configuration
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';

class AppTheme {
  AppTheme._();

  /// Default seed used by [lightTheme] / [darkTheme] when no user color
  /// scheme choice is available yet.
  static const Color _defaultSeed = Color(0xFF2E7D6F);

  /// Build light theme with the given color seed.
  static ThemeData lightThemeFrom(Color seedColor) {
    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(fontFamily: 'Inter');
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light);

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      brightness: Brightness.light,
      colorScheme: scheme,
      textTheme: textTheme,
      extensions: [MedoraColors.forScheme(scheme)],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        side: BorderSide.none,
      ),
      dividerTheme: const DividerThemeData(
        space: 1,
        thickness: 0.5,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 2,
        height: 65,
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: seedColor,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  /// Build dark theme with the given color seed.
  static ThemeData darkThemeFrom(Color seedColor) {
    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .white
        .apply(fontFamily: 'Inter');
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      brightness: Brightness.dark,
      colorScheme: scheme,
      textTheme: textTheme,
      extensions: [MedoraColors.forScheme(scheme)],
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        side: BorderSide.none,
      ),
      dividerTheme: const DividerThemeData(
        space: 1,
        thickness: 0.5,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 2,
        height: 65,
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: seedColor,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  // Keep backward compatibility — default themes use teal
  static ThemeData get lightTheme => lightThemeFrom(_defaultSeed);
  static ThemeData get darkTheme => darkThemeFrom(_defaultSeed);
}
