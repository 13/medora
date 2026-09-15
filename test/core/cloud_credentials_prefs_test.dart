import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/cloud_credentials_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads both keys, or null when either is missing', () async {
    SharedPreferences.setMockInitialValues({
      CloudCredentials.prefsUrlKey: 'https://abc.supabase.co',
      CloudCredentials.prefsKeyKey: 'anon-key',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(
      readCloudCredentials(prefs),
      const CloudCredentials(
        url: 'https://abc.supabase.co',
        anonKey: 'anon-key',
      ),
    );

    SharedPreferences.setMockInitialValues({
      CloudCredentials.prefsUrlKey: 'https://abc.supabase.co',
      CloudCredentials.prefsKeyKey: '  ',
    });
    expect(readCloudCredentials(await SharedPreferences.getInstance()), isNull);

    SharedPreferences.setMockInitialValues({});
    expect(readCloudCredentials(await SharedPreferences.getInstance()), isNull);
  });
}
