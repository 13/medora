import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/stock_alert_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the snapshot survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await StockAlertStore(prefs).save({7: DateTime(2026, 9, 17, 9)});

    expect(StockAlertStore(prefs).load(), {7: DateTime(2026, 9, 17, 9)});
  });

  test('saving an empty snapshot clears the stored one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = StockAlertStore(prefs);

    await store.save({7: DateTime(2026, 9, 17, 9)});
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
    await store.save({1: DateTime(2026, 9, 17, 9)});

    expect(store.load(), {1: DateTime(2026, 9, 17, 9)});
    expect(StockAlertStore.inMemory().load(), isEmpty);
  });
}
