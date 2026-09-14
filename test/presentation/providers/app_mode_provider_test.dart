import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  group('app mode basics', () {
    late SharedPreferences prefs;

    setUp(() async {
      await setUpTestDatabase();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      SupabaseConfig.resetForTest();
    });
    tearDown(tearDownTestDatabase);

    ProviderContainer makeContainer() => ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );

    test('defaults to localOnly', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(appModeProvider), AppMode.localOnly);
    });

    test('set persists across containers', () async {
      final c1 = makeContainer();
      await c1.read(appModeProvider.notifier).set(AppMode.cloud);
      c1.dispose();

      final c2 = makeContainer();
      addTearDown(c2.dispose);
      expect(c2.read(appModeProvider), AppMode.cloud);
    });

    test('remote datasources are null in localOnly mode', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(supabaseClientProvider), isNull);
      expect(c.read(medicationDatasourceProvider), isNull);
      expect(c.read(familyDatasourceProvider), isNull);
    });

    test(
      'remote datasources stay null in cloud mode when the build is unconfigured',
      () async {
        final c = makeContainer();
        addTearDown(c.dispose);
        await c.read(appModeProvider.notifier).set(AppMode.cloud);
        expect(c.read(appModeProvider), AppMode.cloud);
        expect(c.read(supabaseClientProvider), isNull);
        expect(c.read(medicationDatasourceProvider), isNull);
      },
    );

    test(
      'with no app_mode pref, defaults to localOnly when the build is unconfigured',
      () {
        // This exercises only the "not signed in" side of the one-time upgrade
        // migration in AppModeNotifier.build(): SupabaseConfig.isConfigured is
        // false here, so the cloud branch (a pre-existing Supabase session with
        // no app_mode pref yet) can't be exercised without a real, configured
        // Supabase client and session — that path is covered by manual/QA
        // verification instead.
        final c = makeContainer();
        addTearDown(c.dispose);
        expect(c.read(appModeProvider), AppMode.localOnly);
      },
    );
  });

  group('cloud upload marking', () {
    setUp(() async {
      await setUpTestDatabase();
      SharedPreferences.setMockInitialValues({
        'sync.last_pull_at.medications': '2026-01-01T00:00:00.000Z',
      });
    });
    tearDown(tearDownTestDatabase);

    test(
      'switching to cloud only flips the mode; it does not mark or clear',
      () async {
        // Nobody is signed in at this point, so marking here would upload
        // whatever is on the device into whichever account signs in next. The
        // auth screen does the marking once it knows who that is.
        final db = await AppDatabase.instance.database;
        await seedPrescription(db);
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        addTearDown(container.dispose);

        expect(container.read(appModeProvider), AppMode.localOnly);
        await container.read(appModeProvider.notifier).set(AppMode.cloud);

        expect(container.read(appModeProvider), AppMode.cloud);
        expect(prefs.getString('app_mode'), 'cloud');
        expect(
          prefs.getString('sync.last_pull_at.medications'),
          '2026-01-01T00:00:00.000Z',
          reason: 'cursors are cleared at sign-in, not at mode switch',
        );
        final rows = await db.query('medications', columns: ['sync_status']);
        expect(rows.single['sync_status'], SyncStatus.synced);
      },
    );
  });
}
