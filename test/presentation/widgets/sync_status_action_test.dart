import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/sync_status_action.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

class _CloudMode extends AppModeNotifier {
  @override
  AppMode build() => AppMode.cloud;
}

class _LocalMode extends AppModeNotifier {
  @override
  AppMode build() => AppMode.localOnly;
}

/// Counts sync requests; nothing else of the service is used here.
class _CountingSync implements SyncService {
  int calls = 0;

  @override
  Future<SyncReport?> syncAll() async {
    calls++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _CountingSync sync;

  Future<List<Override>> overrides(
    SyncState state, {
    bool cloud = true,
  }) async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    appModeProvider.overrideWith(cloud ? _CloudMode.new : _LocalMode.new),
    syncStateStreamProvider.overrideWith((ref) => Stream.value(state)),
    syncServiceProvider.overrideWithValue(sync),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sync = _CountingSync();
  });

  Future<void> pump(
    WidgetTester tester,
    SyncState state, {
    Locale locale = const Locale('en'),
    bool cloud = true,
  }) async {
    await pumpMedoraApp(
      tester,
      Scaffold(appBar: AppBar(actions: const [SyncStatusAction()])),
      overrides: await overrides(state, cloud: cloud),
      locale: locale,
    );
    // The syncing spinner never settles.
    await tester.pump();
    await tester.pump();
  }

  final button = find.byKey(SyncStatusAction.buttonKey);

  String labelFor(AppLocalizations l10n, SyncState state) => switch (state) {
    SyncState.syncing => l10n.syncing,
    SyncState.error => l10n.syncError,
    SyncState.partial => l10n.syncPartial,
    SyncState.idle || SyncState.success => l10n.syncNow,
  };

  for (final locale in const ['en', 'de', 'it']) {
    for (final state in SyncState.values) {
      testWidgets('${state.name} ($locale): an icon whose tooltip and '
          'screen-reader label carry the status', (tester) async {
        final semantics = tester.ensureSemantics();
        await pump(tester, state, locale: Locale(locale));
        final label = labelFor(lookupAppLocalizations(Locale(locale)), state);
        expect(button, findsOneWidget);
        expect(find.byTooltip(label), findsOneWidget);
        expect(
          tester.getSemantics(button),
          isSemantics(
            tooltip: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: state != SyncState.syncing,
          ),
        );
        // No visible text: the label is what pushed the gear off screen.
        expect(find.text(label), findsNothing);
        final size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        semantics.dispose();
      });
    }
  }

  testWidgets('each state has its own icon, not only its own colour', (
    tester,
  ) async {
    final icons = <SyncState, Object>{};
    for (final state in SyncState.values) {
      await pump(tester, state);
      final icon = find.descendant(of: button, matching: find.byType(Icon));
      icons[state] = icon.evaluate().isEmpty
          ? CircularProgressIndicator
          : tester.widget<Icon>(icon).icon!;
    }
    expect(icons[SyncState.syncing], CircularProgressIndicator);
    expect(icons[SyncState.error], Icons.sync_problem);
    expect(icons[SyncState.partial], Icons.warning_amber_rounded);
    expect(icons[SyncState.idle], Icons.cloud_done_outlined);
    expect(icons[SyncState.success], Icons.cloud_done_outlined);
  });

  for (final state in const [
    SyncState.idle,
    SyncState.success,
    SyncState.error,
    SyncState.partial,
  ]) {
    testWidgets('${state.name}: a tap starts a sync', (tester) async {
      await pump(tester, state);
      await tester.tap(button);
      await tester.pump();
      expect(sync.calls, 1);
    });
  }

  testWidgets('syncing: a tap does nothing', (tester) async {
    await pump(tester, SyncState.syncing);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(sync.calls, 0);
  });

  testWidgets('local-only: nothing is shown', (tester) async {
    await pump(tester, SyncState.error, cloud: false);
    expect(button, findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });
}
