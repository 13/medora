import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/stock_alert_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the snapshot survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await StockAlertStore(prefs).save({7: 'a-fingerprint'});

    expect(StockAlertStore(prefs).load(), {7: 'a-fingerprint'});
  });

  test('saving an empty snapshot clears the stored one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = StockAlertStore(prefs);

    await store.save({7: 'a-fingerprint'});
    await store.save({});

    expect(StockAlertStore(prefs).load(), isEmpty);
  });

  test('a corrupt value reads as an empty snapshot', () async {
    SharedPreferences.setMockInitialValues({
      StockAlertStore.prefsKey: 'not json',
    });
    final prefs = await SharedPreferences.getInstance();

    expect(StockAlertStore(prefs).load(), isEmpty);
  });

  test('the in-memory store keeps the snapshot for one process only', () async {
    final store = StockAlertStore.inMemory();
    await store.save({1: 'a-fingerprint'});

    expect(store.load(), {1: 'a-fingerprint'});
    expect(StockAlertStore.inMemory().load(), isEmpty);
  });

  test('a snapshot written by an older version keeps its ids', () async {
    // The shape before the fingerprint: id → the time it fires. The times
    // are worthless now, but the ids are not — they are the only way those
    // notifications can ever be cancelled.
    SharedPreferences.setMockInitialValues({
      StockAlertStore.prefsKey: jsonEncode({'7': 1790000000000, '9': 1}),
    });
    final prefs = await SharedPreferences.getInstance();

    expect(StockAlertStore(prefs).load(), {
      7: StockAlertStore.unknownFingerprint,
      9: StockAlertStore.unknownFingerprint,
    });
  });

  test('a snapshot from a newer version keeps its ids', () async {
    SharedPreferences.setMockInitialValues({
      StockAlertStore.prefsKey: jsonEncode({
        'v': StockAlertStore.version + 1,
        'alerts': {
          '7': {'when': 1, 'extra': 'something'},
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    expect(StockAlertStore(prefs).load(), {
      7: StockAlertStore.unknownFingerprint,
    });
  });

  test('one unreadable row does not cost the other ids', () async {
    SharedPreferences.setMockInitialValues({
      StockAlertStore.prefsKey: jsonEncode({
        'v': StockAlertStore.version,
        'alerts': {'7': 'a-fingerprint', 'not-an-id': 'x', '9': 12},
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    expect(StockAlertStore(prefs).load(), {
      7: 'a-fingerprint',
      // The id is readable even though its value is not; keeping it is what
      // lets the alert be cancelled rather than orphaned.
      9: StockAlertStore.unknownFingerprint,
    });
  });
}
