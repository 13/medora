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
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:medora/presentation/widgets/settings_action.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/pump_shell.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

class _CloudMode extends AppModeNotifier {
  @override
  AppMode build() => AppMode.cloud;
}

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

  // The shell above runs local-only, where the Dashboard has no sync status.
  // In cloud mode it had a full-text chip that, in German and Italian, pushed
  // the gear off screen and squeezed the title to nothing even at 1.0x.
  group('Dashboard in cloud mode', () {
    Future<void> pumpCloudHome(
      WidgetTester tester, {
      required Size size,
      required String locale,
      required double scale,
      required SyncState state,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      await pumpMedoraApp(
        tester,
        withTextScale(scale, const HomeScreen()),
        locale: Locale(locale),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          // Mobile: the scanner action takes a slot too, the tightest case.
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.mobile,
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 3, 4, 15)),
          appModeProvider.overrideWith(_CloudMode.new),
          syncStateStreamProvider.overrideWith((ref) => Stream.value(state)),
        ],
      );
      // Not pumpAndSettle: the syncing state spins for ever.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    for (final state in SyncState.values) {
      for (final locale in const ['de', 'it', 'en']) {
        for (final (size, scale) in const [
          (Size(360, 800), 1.0),
          (Size(360, 800), 1.6),
          (Size(412, 915), 1.0),
          (Size(320, 640), 1.3),
        ]) {
          testWidgets('${state.name}, $locale, ${size.width.toInt()} dp, '
              '${scale}x: the title, the sync status and the gear all fit', (
            tester,
          ) async {
            await pumpCloudHome(
              tester,
              size: size,
              locale: locale,
              scale: scale,
              state: state,
            );
            final where =
                'Dashboard (cloud, ${state.name}, $locale, '
                '${size.width}, ${scale}x)';
            expect(tester.takeException(), isNull, reason: where);
            final gear = tester.getRect(find.byKey(SettingsAction.buttonKey));
            expect(gear.left, greaterThanOrEqualTo(0), reason: where);
            expect(gear.right, lessThanOrEqualTo(size.width), reason: where);
            expect(gear.width, greaterThanOrEqualTo(48), reason: where);
            final bar = find.byType(AppBar);
            for (final e
                in find
                    .descendant(of: bar, matching: find.byType(IconButton))
                    .evaluate()) {
              final r = tester.getRect(find.byElementPredicate((x) => x == e));
              expect(r.left, greaterThanOrEqualTo(0), reason: where);
              expect(r.right, lessThanOrEqualTo(size.width), reason: where);
            }
            // Scanner, sync status and gear.
            expect(
              find.descendant(of: bar, matching: find.byType(IconButton)),
              findsNWidgets(3),
              reason: where,
            );
            expectAppBarTextFits(tester, where);
          });
        }
      }
    }
  });
}
