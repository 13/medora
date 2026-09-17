/// The four main app bars with the gear, measured in the app's real fonts:
/// the gear must not push a title into an ellipsis, and no app-bar label may
/// be wider than its box.
///
/// Clipped text throws nothing, so this compares what each label wants with
/// what it got (see test/helpers/text_fit.dart). The overflow checks for the
/// same screens are in settings_gear_test.dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/widgets/settings_action.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_shell.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

void main() {
  setUpAll(loadAppFonts);
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  /// Every label in the visible app bar fits on its one line, whole.
  void expectAppBarTextFits(WidgetTester tester, String where) {
    final labels = find.descendant(
      of: find.byType(AppBar).last,
      matching: find.byType(RichText),
    );
    // The title plus at least one icon glyph per action.
    expect(labels.evaluate().length, greaterThanOrEqualTo(3), reason: where);
    for (final element in labels.evaluate()) {
      final label = find.byElementPredicate((e) => e == element);
      final text = (element.widget as RichText).text.toPlainText();
      final fit = measureText(tester, label);
      printOnFailure('$where "$text": $fit');
      // App-bar titles are single-line and ellipsized, so the whole text,
      // not only its longest word, has to fit.
      expect(
        fit.maxIntrinsic,
        lessThanOrEqualTo(fit.maxWidth + 0.5),
        reason: '"$text" is cut on $where',
      );
      expect(fit.exceeded, isFalse, reason: '"$text" is cut on $where');
    }
  }

  for (final (locale, scale) in const [
    ('de', 1.6),
    ('it', 1.6),
    ('en', 1.6),
    ('de', 2.0),
  ]) {
    for (final (index, tab) in mainTabs.indexed) {
      testWidgets('$tab at 360 dp, $locale, ${scale}x text: the title and '
          'every action fit beside the gear', (tester) async {
        // At 2.0x some page bodies overflow already (outside the app bar, see
        // the design's deferred list); they are not this test's subject.
        await collectFlutterErrors(() async {
          await pumpShell(
            tester,
            size: const Size(360, 800),
            locale: Locale(locale),
            textScale: scale,
          );
          await openTab(tester, index);
        });
        expect(find.byKey(SettingsAction.buttonKey), findsOneWidget);
        expectAppBarTextFits(tester, '$tab ($locale, ${scale}x)');
      });
    }
  }
}
