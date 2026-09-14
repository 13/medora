/// Medora - App Theme Configuration
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';

class AppTheme {
  AppTheme._();

  // Default Brand Colors (used for status indicators — these don't change)
  @Deprecated('Use context.colors.primary')
  static const Color primaryColor = Color(0xFF2E7D6F);
  @Deprecated('Use context.medora')
  static const Color primaryLight = Color(0xFF4CAF9E);
  @Deprecated('Use context.medora')
  static const Color primaryDark = Color(0xFF1B5E50);
  @Deprecated('Use context.medora')
  static const Color accentColor = Color(0xFFFF8A65);
  @Deprecated('Use context.medora')
  static const Color errorColor = Color(0xFFE53935);
  @Deprecated('Use context.medora')
  static const Color warningColor = Color(0xFFFFA726);
  @Deprecated('Use context.medora')
  static const Color successColor = Color(0xFF66BB6A);

  // Status Colors
  @Deprecated('Use context.medora')
  static const Color expiringSoonColor = Color(0xFFFFA726);
  @Deprecated('Use context.medora')
  static const Color expiredColor = Color(0xFFE53935);
  @Deprecated('Use context.medora')
  static const Color lowStockColor = Color(0xFFFF7043);
  @Deprecated('Use context.medora')
  static const Color inStockColor = Color(0xFF66BB6A);

  // Dose Status Colors
  @Deprecated('Use context.medora')
  static const Color doseTakenColor = Color(0xFF66BB6A);
  @Deprecated('Use context.medora')
  static const Color doseSkippedColor = Color(0xFFFFA726);
  @Deprecated('Use context.medora')
  static const Color doseMissedColor = Color(0xFFE53935);
  @Deprecated('Use context.medora')
  static const Color dosePendingColor = Color(0xFF90A4AE);

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
  static ThemeData get lightTheme => lightThemeFrom(primaryColor);
  static ThemeData get darkTheme => darkThemeFrom(primaryColor);
}
