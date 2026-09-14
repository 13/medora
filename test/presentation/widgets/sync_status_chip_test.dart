import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/sync_status_chip.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

class _CloudMode extends AppModeNotifier {
  @override
  AppMode build() => AppMode.cloud;
}

void main() {
  Future<List<Override>> overrides(SyncState state) async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    appModeProvider.overrideWith(_CloudMode.new),
    syncStateStreamProvider.overrideWith((ref) => Stream.value(state)),
  ];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('partial state shows the warning label', (tester) async {
    await pumpMedoraApp(
      tester,
      const Scaffold(body: SyncStatusChip()),
      overrides: await overrides(SyncState.partial),
    );
    await tester.pumpAndSettle();
    expect(find.text('Completed with some errors'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('idle state offers Sync Now', (tester) async {
    await pumpMedoraApp(
      tester,
      const Scaffold(body: SyncStatusChip()),
      overrides: await overrides(SyncState.idle),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sync Now'), findsOneWidget);
  });
}
