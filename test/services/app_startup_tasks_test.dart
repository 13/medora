import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/app_startup_tasks.dart';

void main() {
  test('runs sync after the delay, then maintenance, then reminders', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('maintenance'),
      reminders: () async => calls.add('reminders'),
      sync: () async => calls.add('sync'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
    );
    await tasks.run();
    expect(calls, ['sync', 'maintenance', 'reminders']);
  });

  test('without a sync, maintenance runs at once', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('maintenance'),
      reminders: () async => calls.add('reminders'),
      sync: () async => calls.add('sync'),
      syncEnabled: () => false,
      syncDelay: const Duration(hours: 1),
      minSyncInterval: Duration.zero,
    );
    await tasks.run().timeout(const Duration(seconds: 5));
    expect(calls, ['maintenance', 'reminders']);
  });

  test('the update check runs last, after sync', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('maintenance'),
      reminders: () async => calls.add('reminders'),
      sync: () async => calls.add('sync'),
      updateCheck: () async => calls.add('updateCheck'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
      minUpdateCheckInterval: Duration.zero,
    );
    await tasks.run();
    expect(calls, ['sync', 'maintenance', 'reminders', 'updateCheck']);
  });

  test('the update check still runs when sync is skipped', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async {},
      reminders: () async {},
      sync: () async => calls.add('sync'),
      updateCheck: () async => calls.add('updateCheck'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
      minUpdateCheckInterval: Duration.zero,
    );
    await tasks.run(includeSync: false);
    expect(calls, ['updateCheck']);
  });

  test('a failing update check does not escape run()', () async {
    final tasks = AppStartupTasks(
      maintenance: () async {},
      reminders: () async {},
      sync: () async {},
      updateCheck: () async => throw StateError('offline'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
      minUpdateCheckInterval: Duration.zero,
    );
    await expectLater(tasks.run(), completes);
  });

  test('the update check is skipped inside minUpdateCheckInterval', () async {
    var checks = 0;
    var clock = DateTime(2026, 3, 1, 9);
    final tasks = AppStartupTasks(
      maintenance: () async {},
      reminders: () async {},
      sync: () async {},
      updateCheck: () async => checks++,
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
      now: () => clock,
    );
    await tasks.run();
    clock = clock.add(const Duration(hours: 5));
    await tasks.run();
    expect(checks, 1);
    clock = clock.add(const Duration(hours: 19));
    await tasks.run();
    expect(checks, 2);
  });

  test('includeSync=false skips sync', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('m'),
      reminders: () async => calls.add('r'),
      sync: () async => calls.add('s'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
    );
    await tasks.run(includeSync: false);
    expect(calls, ['m', 'r']);
  });

  test('a failing step does not stop the others', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => throw StateError('boom'),
      reminders: () async => calls.add('r'),
      sync: () async => calls.add('s'),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
    );
    await tasks.run();
    expect(calls, ['s', 'r']);
  });

  test('concurrent runs are coalesced', () async {
    var maintenanceRuns = 0;
    final tasks = AppStartupTasks(
      maintenance: () async {
        maintenanceRuns++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      reminders: () async {},
      sync: () async {},
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
    );
    await Future.wait([tasks.run(), tasks.run()]);
    expect(maintenanceRuns, 1);
  });

  test(
    'sync is skipped when the last sync was within minSyncInterval',
    () async {
      var syncs = 0;
      var clock = DateTime(2026, 3, 1, 9);
      final tasks = AppStartupTasks(
        maintenance: () async {},
        reminders: () async {},
        sync: () async => syncs++,
        syncDelay: Duration.zero,
        minSyncInterval: const Duration(minutes: 5),
        now: () => clock,
      );
      await tasks.run();
      clock = clock.add(const Duration(minutes: 1));
      await tasks.run();
      expect(syncs, 1);
      clock = clock.add(const Duration(minutes: 5));
      await tasks.run();
      expect(syncs, 2);
    },
  );
}
