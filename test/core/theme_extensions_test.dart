import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/core/theme_extensions.dart';

import '../helpers/contrast.dart';

void main() {
  for (final (label, theme) in [('light', AppTheme.lightThemeFrom(Colors.teal)), ('dark', AppTheme.darkThemeFrom(Colors.teal))]) {
    test('$label theme registers MedoraColors with readable pairs', () {
      final m = theme.extension<MedoraColors>();
      expect(m, isNotNull);
      for (final (fg, bg) in [
        (m!.onSuccess, m.success), (m.onSuccessContainer, m.successContainer),
        (m.onWarning, m.warning), (m.onWarningContainer, m.warningContainer),
        (m.onDanger, m.danger), (m.onDangerContainer, m.dangerContainer),
        (m.onNeutral, m.neutral), (m.onNeutralContainer, m.neutralContainer),
      ]) {
        expect(contrastRatio(fg, bg), greaterThanOrEqualTo(3.0), reason: '$label pair $fg on $bg');
      }
    });

    test('$label theme colorScheme.primaryContainer pair is readable', () {
      final scheme = theme.colorScheme;
      expect(
        contrastRatio(scheme.onPrimaryContainer, scheme.primaryContainer),
        greaterThanOrEqualTo(3.0),
      );
    });
  }

  test('semantic aliases map to the base roles', () {
    final m = AppTheme.lightThemeFrom(Colors.teal).extension<MedoraColors>()!;
    expect(m.doseTaken, m.success);
    expect(m.doseMissed, m.danger);
    expect(m.expiringSoon, m.warning);
    expect(m.dosePending, m.neutral);
  });

  testWidgets('context accessors resolve', (tester) async {
    late MedoraColors seen;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightThemeFrom(Colors.teal),
      home: Builder(builder: (context) { seen = context.medora; return const SizedBox(); }),
    ));
    expect(seen.success, isNotNull);
  });
}
