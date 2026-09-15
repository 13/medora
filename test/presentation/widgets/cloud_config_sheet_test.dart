import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/cloud_config_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

const _url = 'https://abcdefgh.supabase.co';
const _key = 'sb-publishable-key';

void main() {
  late SharedPreferences prefs;
  CloudConfigOutcome? outcome;

  setUp(() async {
    outcome = null;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// Opens the sheet; the result lands in [outcome] once it closes.
  Future<void> open(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
  }) async {
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => outcome = await showCloudConfigSheet(context),
          child: const Text('open'),
        ),
      ),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ...extraOverrides,
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('refuses a URL that is not https and an empty key', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(
      find.byKey(CloudConfigSheet.urlFieldKey),
      'http://abcdefgh.supabase.co',
    );
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('starting with https://'),
      findsOneWidget,
      reason: 'the URL error should be shown',
    );
    expect(prefs.getString(CloudCredentials.prefsUrlKey), isNull);

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('anon or publishable key'), findsOneWidget);
    expect(prefs.getString(CloudCredentials.prefsKeyKey), isNull);
  });

  testWidgets('saving stores the credentials and activates cloud', (
    tester,
  ) async {
    CloudCredentials? activated;
    await open(
      tester,
      extraOverrides: [
        cloudActivatorProvider.overrideWithValue((creds) async {
          activated = creds;
          return true;
        }),
      ],
    );

    await tester.enterText(
      find.byKey(CloudConfigSheet.urlFieldKey),
      '  $_url/  ',
    );
    await tester.enterText(
      find.byKey(CloudConfigSheet.keyFieldKey),
      '  $_key ',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(prefs.getString(CloudCredentials.prefsUrlKey), _url);
    expect(prefs.getString(CloudCredentials.prefsKeyKey), _key);
    expect(activated, const CloudCredentials(url: _url, anonKey: _key));
    expect(outcome, CloudConfigOutcome.savedAndActive);
  });

  testWidgets('saving into a running app asks for a restart', (tester) async {
    await open(
      tester,
      extraOverrides: [
        cloudActivatorProvider.overrideWithValue((_) async => false),
      ],
    );

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(outcome, CloudConfigOutcome.savedNeedsRestart);
  });

  testWidgets('a failing activation keeps the sheet open and says why', (
    tester,
  ) async {
    await open(
      tester,
      extraOverrides: [
        cloudActivatorProvider.overrideWithValue(
          (_) async => throw StateError('supabase says no'),
        ),
      ],
    );

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(outcome, isNull, reason: 'the sheet must stay open');
    expect(find.textContaining('supabase says no'), findsOneWidget);
    // Still usable: the values are untouched and Save can be tried again.
    expect(
      tester
          .widget<TextField>(find.byKey(CloudConfigSheet.urlFieldKey))
          .controller
          ?.text,
      _url,
    );
    final save = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Save'), matching: find.byType(FilledButton)),
    );
    expect(save.onPressed, isNotNull, reason: '_saving must be reset');

    // A second, working attempt still goes through.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('supabase says no'), findsOneWidget);
  });

  testWidgets('test connection reports the probe result and sends the key as '
      'a header', (tester) async {
    http.Request? seen;
    await open(
      tester,
      extraOverrides: [
        cloudHttpClientProvider.overrideWithValue(
          MockClient((request) async {
            seen = request;
            return http.Response('{}', 200);
          }),
        ),
      ],
    );

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(seen?.url.toString(), '$_url/auth/v1/settings');
    expect(seen?.headers['apikey'], _key);
    expect(find.textContaining('answered'), findsOneWidget);
  });

  testWidgets('a probe that never answers gives up instead of spinning', (
    tester,
  ) async {
    await open(
      tester,
      extraOverrides: [
        cloudHttpClientProvider.overrideWithValue(
          MockClient((_) => Completer<http.Response>().future),
        ),
      ],
    );

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(cloudProbeTimeout + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not reach'), findsOneWidget);
  });

  testWidgets('a failing probe never shows the key', (tester) async {
    await open(
      tester,
      extraOverrides: [
        cloudHttpClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('nope', 401)),
        ),
      ],
    );

    await tester.enterText(find.byKey(CloudConfigSheet.urlFieldKey), _url);
    await tester.enterText(find.byKey(CloudConfigSheet.keyFieldKey), _key);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reach'), findsOneWidget);
    // The failure never spells the key out, and the field keeps it obscured.
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '');
    expect(labels.any((l) => l.contains(_key)), isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(CloudConfigSheet.keyFieldKey))
          .obscureText,
      isTrue,
    );
  });

  testWidgets('a stored key stays masked until Replace is tapped', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      CloudCredentials.prefsUrlKey: _url,
      CloudCredentials.prefsKeyKey: _key,
    });
    prefs = await SharedPreferences.getInstance();

    await open(tester);

    expect(find.text('••••••••'), findsOneWidget);
    expect(find.text(_key), findsNothing);
    expect(find.byKey(CloudConfigSheet.keyFieldKey), findsNothing);

    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(find.byKey(CloudConfigSheet.keyFieldKey), findsOneWidget);
    expect(find.text(_key), findsNothing);
  });

  testWidgets('clearing hands the decision back to the caller', (tester) async {
    SharedPreferences.setMockInitialValues({
      CloudCredentials.prefsUrlKey: _url,
      CloudCredentials.prefsKeyKey: _key,
    });
    prefs = await SharedPreferences.getInstance();

    await open(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(outcome, CloudConfigOutcome.clearRequested);
  });
}
