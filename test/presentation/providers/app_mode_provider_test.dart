import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

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

  test('remote datasources stay null in cloud mode when the build is unconfigured', () async {
    final c = makeContainer();
    addTearDown(c.dispose);
    await c.read(appModeProvider.notifier).set(AppMode.cloud);
    expect(c.read(supabaseClientProvider), isNull);
    expect(c.read(medicationDatasourceProvider), isNull);
  });
}
