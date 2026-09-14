import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/theme.dart';

void main() {
  test('themes use the bundled Inter family (no runtime font download)', () {
    final light = AppTheme.lightThemeFrom(Colors.teal);
    final dark = AppTheme.darkThemeFrom(Colors.teal);
    expect(light.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(dark.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(light.useMaterial3, isTrue);
  });
}
