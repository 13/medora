import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_update_service.dart';

/// A download that stalls until the test lets it through, one [Completer] per
/// call, and that reports a chunk *after* it learns it was cancelled - which
/// is exactly the moment a stale download could write over a live one.
class _StalledUpdateService extends FakeUpdateService {
  _StalledUpdateService({required super.release});

  final gates = <Completer<void>>[];

  /// The progress the nth call reports before and after its gate.
  static double markOf(int call) => 0.1 * call;

  @override
  Future<File> download(
    ReleaseInfo release,
    ReleaseAsset asset,
    Directory dir, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final gate = Completer<void>();
    gates.add(gate);
    final mark = markOf(gates.length);
    onProgress?.call(mark);
    await gate.future;
    if (isCancelled?.call() ?? false) {
      onProgress?.call(mark + 0.5);
      throw const UpdateException(UpdateErrorKind.cancelled, 'cancelled');
    }
    onProgress?.call(1);
    return File(p.join(dir.path, asset.name))..writeAsBytesSync(const [1, 2]);
  }
}

/// A download that never looks at [isCancelled] and always finishes, leaving
/// the APK in `updates/` the way a cancel on the very last chunk would.
class _UncancellableUpdateService extends FakeUpdateService {
  _UncancellableUpdateService({required super.release});

  final gate = Completer<void>();

  @override
  Future<File> download(
    ReleaseInfo release,
    ReleaseAsset asset,
    Directory dir, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call(0.5);
    await gate.future;
    final updates = Directory(p.join(dir.path, AppUpdateService.updatesFolder))
      ..createSync(recursive: true);
    return File(p.join(updates.path, asset.name))
      ..writeAsBytesSync(const [1, 2]);
  }
}

void main() {
  const current = fakeCurrentVersion;
  late Directory root;
  late DateTime clock;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('medora_update_provider');
    clock = DateTime.utc(2026, 3, 4, 15);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ReleaseInfo releaseOf(ReleaseVersion version) => fakeRelease(version);

  Future<ProviderContainer> containerWith(
    FakeUpdateService service, {
    PlatformCapabilities caps = PlatformCapabilities.mobile,
    String repo = 'acme/medora',
    bool online = true,
    ReleaseVersion current = fakeCurrentVersion,
  }) async {
    final container = ProviderContainer(
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
        caps: caps,
        repo: repo,
        online: online,
        current: current,
      ),
    );
    addTearDown(container.dispose);
    await container.read(appUpdateProvider.future);
    return container;
  }

  UpdateStatus statusOf(ProviderContainer c) =>
      c.read(appUpdateProvider).requireValue;

  group('check', () {
    test('reports an available update when the release is newer', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();

      final status = statusOf(c);
      expect(status, isA<UpdateAvailable>());
      expect((status as UpdateAvailable).release.tag, 'v0.2.0+12');
      expect(status.asset.name, 'medora-0.2.0-12-arm64-v8a.apk');
    });

    test('reports up to date when the release is not newer', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();

      expect(statusOf(c), isA<UpdateUpToDate>());
      expect((statusOf(c) as UpdateUpToDate).current, current);
    });

    test('writes update.last_check_at as an ISO UTC timestamp', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();

      final prefs = c.read(sharedPreferencesProvider);
      expect(
        DateTime.parse(prefs.getString(kUpdateLastCheckAt)!).toUtc(),
        clock.toUtc(),
      );
    });

    test('a second check inside 24 h does not hit the network', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();
      clock = clock.add(const Duration(hours: 23));
      await c.read(appUpdateProvider.notifier).check();
      expect(service.checks, 1);

      clock = clock.add(const Duration(hours: 2));
      await c.read(appUpdateProvider.notifier).check();
      expect(service.checks, 2);
    });

    test('force: true ignores the 24 h throttle', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();
      await c.read(appUpdateProvider.notifier).check(force: true);

      expect(service.checks, 2);
    });

    test(
      'offline resolves to the previous state without a network call',
      () async {
        final service = FakeUpdateService(release: releaseOf(current));
        var online = true;
        final c = ProviderContainer(
          overrides: await updateOverrides(
            service: service,
            downloadDir: root,
            now: () => clock,
            isOnline: () => online,
          ),
        );
        addTearDown(c.dispose);
        await c.read(appUpdateProvider.future);

        // Seed a real prior status first, so "resolves to the previous
        // state" is actually exercised rather than coinciding with the
        // UpdateUnknown a fresh notifier starts with.
        await c.read(appUpdateProvider.notifier).check(force: true);
        expect(statusOf(c), isA<UpdateUpToDate>());
        final lastCheckAt = c
            .read(sharedPreferencesProvider)
            .getString(kUpdateLastCheckAt);
        expect(lastCheckAt, isNotNull);

        online = false;
        await c.read(appUpdateProvider.notifier).check(force: true);

        expect(service.checks, 1);
        expect(statusOf(c), isA<UpdateUpToDate>());
        expect(
          c.read(sharedPreferencesProvider).getString(kUpdateLastCheckAt),
          lastCheckAt,
        );
      },
    );

    test('a platform without in-app updates stays unknown', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(
        service,
        caps: PlatformCapabilities.desktop,
      );

      await c.read(appUpdateProvider.notifier).check(force: true);

      expect(service.checks, 0);
      expect(statusOf(c), isA<UpdateUnknown>());
    });

    test('an empty UPDATE_REPO disables the check', () async {
      final service = FakeUpdateService(release: releaseOf(current));
      final c = await containerWith(service, repo: '');

      await c.read(appUpdateProvider.notifier).check(force: true);

      expect(service.checks, 0);
      expect(statusOf(c), isA<UpdateUnknown>());
    });

    test('a release without an installable asset fails with noAsset', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        hasAsset: false,
      );
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();

      final status = statusOf(c);
      expect(status, isA<UpdateFailed>());
      expect((status as UpdateFailed).error.kind, UpdateErrorKind.noAsset);
    });

    test('a network failure becomes UpdateFailed', () async {
      final service = FakeUpdateService(
        error: const UpdateException(UpdateErrorKind.network, 'no route'),
      );
      final c = await containerWith(service);

      await c.read(appUpdateProvider.notifier).check();

      expect(statusOf(c), isA<UpdateFailed>());
      expect((statusOf(c) as UpdateFailed).error.kind, UpdateErrorKind.network);
    });
  });

  group('download and install', () {
    Future<ProviderContainer> withAvailable(FakeUpdateService service) async {
      final c = await containerWith(service);
      await c.read(appUpdateProvider.notifier).check();
      expect(statusOf(c), isA<UpdateAvailable>());
      return c;
    }

    test('download streams progress and ends in UpdateReady', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);

      final seen = <UpdateStatus>[];
      final sub = c.listen(appUpdateProvider, (_, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      });
      addTearDown(sub.close);

      await c.read(appUpdateProvider.notifier).download();

      final progress = seen.whereType<UpdateDownloading>().map(
        (s) => s.progress,
      );
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      final status = statusOf(c);
      expect(status, isA<UpdateReady>());
      expect(
        (status as UpdateReady).file.path,
        p.join(root.path, 'medora-0.2.0-12-arm64-v8a.apk'),
      );
    });

    test('a failed download becomes UpdateFailed', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        downloadError: const UpdateException(
          UpdateErrorKind.checksum,
          'bad hash',
        ),
      );
      final c = await withAvailable(service);

      await c.read(appUpdateProvider.notifier).download();

      expect(statusOf(c), isA<UpdateFailed>());
      expect(
        (statusOf(c) as UpdateFailed).error.kind,
        UpdateErrorKind.checksum,
      );
    });

    test('cancelDownload puts the release back on offer', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      final notifier = c.read(appUpdateProvider.notifier);

      final done = notifier.download();
      expect(statusOf(c), isA<UpdateDownloading>());

      notifier.cancelDownload();
      expect(statusOf(c), isA<UpdateAvailable>());

      await done;
      expect(statusOf(c), isA<UpdateAvailable>());
      expect(
        (statusOf(c) as UpdateAvailable).release.tag,
        'v0.2.0+12',
        reason: 'the same release is still the one to download',
      );
    });

    test('cancelDownload outside a download does nothing', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);

      c.read(appUpdateProvider.notifier).cancelDownload();

      expect(statusOf(c), isA<UpdateAvailable>());
    });

    test('a cancelled download can be started again', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      final notifier = c.read(appUpdateProvider.notifier);

      final cancelled = notifier.download();
      notifier.cancelDownload();
      await cancelled;

      await notifier.download();

      expect(statusOf(c), isA<UpdateReady>());
    });

    test(
      'a re-download while the cancelled one unwinds keeps the state',
      () async {
        final service = _StalledUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await withAvailable(service);
        final notifier = c.read(appUpdateProvider.notifier);

        final seen = <UpdateStatus>[];
        final sub = c.listen(appUpdateProvider, (_, next) {
          final value = next.value;
          if (value != null) seen.add(value);
        });
        addTearDown(sub.close);

        final first = notifier.download();
        await pumpEventQueue();
        expect(service.gates, hasLength(1));

        notifier.cancelDownload();
        expect(statusOf(c), isA<UpdateAvailable>());

        final second = notifier.download();
        await pumpEventQueue();
        expect(service.gates, hasLength(2));

        // The cancelled download only now reaches its last chunk.
        service.gates.first.complete();
        await first;
        expect(
          statusOf(c),
          isA<UpdateDownloading>(),
          reason: 'the second download still owns the state',
        );

        service.gates.last.complete();
        await second;
        expect(statusOf(c), isA<UpdateReady>());

        final progress = seen.whereType<UpdateDownloading>().map(
          (s) => s.progress,
        );
        expect(
          progress,
          isNot(contains(_StalledUpdateService.markOf(1) + 0.5)),
          reason: 'the cancelled download reported after it was told to stop',
        );
      },
    );

    test(
      'a second cancel stops the download that replaced the first',
      () async {
        final service = _StalledUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await withAvailable(service);
        final notifier = c.read(appUpdateProvider.notifier);

        final first = notifier.download();
        await pumpEventQueue();
        notifier.cancelDownload();
        final second = notifier.download();
        await pumpEventQueue();
        expect(statusOf(c), isA<UpdateDownloading>());

        notifier.cancelDownload();
        expect(statusOf(c), isA<UpdateAvailable>());

        service.gates.first.complete();
        service.gates.last.complete();
        await first;
        await second;

        expect(statusOf(c), isA<UpdateAvailable>());
        expect(
          (statusOf(c) as UpdateAvailable).release.tag,
          'v0.2.0+12',
          reason: 'the release is still the one to download',
        );
      },
    );

    test('an APK that lands after the cancel is not kept', () async {
      final service = _UncancellableUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      final notifier = c.read(appUpdateProvider.notifier);

      final done = notifier.download();
      await pumpEventQueue();
      notifier.cancelDownload();
      service.gate.complete();
      await done;

      expect(statusOf(c), isA<UpdateAvailable>());
      expect(AppUpdateService.downloadedApk(root), isNull);
    });

    test('install hands the downloaded file to the service', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      await c.read(appUpdateProvider.notifier).download();

      await c.read(appUpdateProvider.notifier).install();

      expect(service.installed, hasLength(1));
      expect(
        service.installed.single.path,
        p.join(root.path, 'medora-0.2.0-12-arm64-v8a.apk'),
      );
    });

    test('install without a downloaded file does nothing', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);

      await c.read(appUpdateProvider.notifier).install();

      expect(service.installed, isEmpty);
    });

    test('a check does not clobber a download in flight', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);

      final downloadDone = c.read(appUpdateProvider.notifier).download();
      expect(statusOf(c), isA<UpdateDownloading>());

      await c.read(appUpdateProvider.notifier).check(force: true);
      expect(statusOf(c), isA<UpdateDownloading>());
      expect(service.checks, 1);

      await downloadDone;
      expect(statusOf(c), isA<UpdateReady>());
    });

    test(
      'a check does not clobber a verified download waiting to install',
      () async {
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await withAvailable(service);
        await c.read(appUpdateProvider.notifier).download();
        expect(statusOf(c), isA<UpdateReady>());

        await c.read(appUpdateProvider.notifier).check(force: true);

        expect(statusOf(c), isA<UpdateReady>());
        expect(service.checks, 1);
      },
    );
  });

  group('install lifecycle', () {
    /// An APK sitting in `<root>/updates/`, as a real download would leave it.
    File seedDownloadedApk([String name = 'medora-0.2.0-12-arm64-v8a.apk']) {
      final updates = Directory(p.join(root.path, 'updates'))
        ..createSync(recursive: true);
      return File(p.join(updates.path, name))..writeAsBytesSync(const [1, 2]);
    }

    Future<ProviderContainer> withAvailable(FakeUpdateService service) async {
      final c = await containerWith(service);
      await c.read(appUpdateProvider.notifier).check();
      expect(statusOf(c), isA<UpdateAvailable>());
      return c;
    }

    test('install records the tag it handed to the installer', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      await c.read(appUpdateProvider.notifier).download();

      await c.read(appUpdateProvider.notifier).install();

      expect(
        c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
        'v0.2.0+12',
      );
    });

    test(
      'a restart on the installed release clears the APK and the pref',
      () async {
        final apk = seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
        });
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await containerWith(
          service,
          current: const ReleaseVersion(0, 2, 0, 12),
        );

        expect(statusOf(c), isA<UpdateUnknown>());
        expect(apk.existsSync(), isFalse);
        expect(
          c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
          isNull,
        );
      },
    );

    test(
      'a cancelled installer leaves the APK ready to install again',
      () async {
        final apk = seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
        });
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await containerWith(service);

        final status = statusOf(c);
        expect(status, isA<UpdateReady>());
        expect((status as UpdateReady).release.tag, 'v0.2.0+12');
        expect(status.file.path, apk.path);
        expect(apk.existsSync(), isTrue);
      },
    );

    test('a pending tag whose APK is gone is settled, not restored', () async {
      SharedPreferences.setMockInitialValues({
        kUpdateInstallingTag: 'v0.2.0+12',
      });
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await containerWith(service);

      expect(statusOf(c), isA<UpdateUnknown>());
      expect(
        c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
        isNull,
      );
    });

    test(
      'a check after a successful install still looks for a release',
      () async {
        final apk = seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
        });
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await containerWith(
          service,
          current: const ReleaseVersion(0, 2, 0, 12),
        );

        await c.read(appUpdateProvider.notifier).check();

        expect(service.checks, 1);
        expect(statusOf(c), isA<UpdateUpToDate>());
        expect(apk.existsSync(), isFalse);
      },
    );

    test(
      'a throttled check reports the cancelled install and asks nothing',
      () async {
        seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
          kUpdateLastCheckAt: clock.toIso8601String(),
        });
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await containerWith(service);

        await c.read(appUpdateProvider.notifier).check();

        expect(service.checks, 0);
        expect(statusOf(c), isA<UpdateReady>());
      },
    );

    test(
      'a forced check keeps a pending install GitHub has not passed',
      () async {
        final apk = seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
        });
        final service = FakeUpdateService(
          release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
        );
        final c = await containerWith(service);

        await c.read(appUpdateProvider.notifier).check(force: true);

        expect(service.checks, 1, reason: 'the pin must not pin the updater');
        expect(statusOf(c), isA<UpdateReady>());
        expect((statusOf(c) as UpdateReady).release.tag, 'v0.2.0+12');
        expect(apk.existsSync(), isTrue);
        expect(
          c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
          'v0.2.0+12',
        );
      },
    );

    test('a release newer than the pending APK takes it over', () async {
      final apk = seedDownloadedApk();
      SharedPreferences.setMockInitialValues({
        kUpdateInstallingTag: 'v0.2.0+12',
      });
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 3, 0, 13)),
      );
      final c = await containerWith(service);
      expect(statusOf(c), isA<UpdateReady>());

      await c.read(appUpdateProvider.notifier).check(force: true);

      final status = statusOf(c);
      expect(status, isA<UpdateAvailable>());
      expect((status as UpdateAvailable).release.tag, 'v0.3.0+13');
      expect(apk.existsSync(), isFalse, reason: 'the overtaken APK is gone');
      expect(
        c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
        isNull,
      );
    });

    test(
      'a check that cannot reach GitHub leaves the pending install up',
      () async {
        final apk = seedDownloadedApk();
        SharedPreferences.setMockInitialValues({
          kUpdateInstallingTag: 'v0.2.0+12',
        });
        final service = FakeUpdateService(
          error: const UpdateException(UpdateErrorKind.network, 'no route'),
        );
        final c = await containerWith(service);

        await c.read(appUpdateProvider.notifier).check(force: true);

        expect(service.checks, 1);
        expect(statusOf(c), isA<UpdateReady>());
        expect(apk.existsSync(), isTrue);
        expect(
          c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
          'v0.2.0+12',
        );
      },
    );

    test('"Later" on a pending install throws the APK away', () async {
      final apk = seedDownloadedApk();
      SharedPreferences.setMockInitialValues({
        kUpdateInstallingTag: 'v0.2.0+12',
      });
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await containerWith(service);
      expect(statusOf(c), isA<UpdateReady>());

      await c.read(appUpdateProvider.notifier).dismiss();

      expect(apk.existsSync(), isFalse);
      expect(
        c.read(sharedPreferencesProvider).getString(kUpdateInstallingTag),
        isNull,
      );
      expect(c.read(updateDismissedTagProvider), 'v0.2.0+12');
      expect(statusOf(c), isA<UpdateUnknown>());
    });

    test('"Later" on a freshly downloaded APK keeps it', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await withAvailable(service);
      await c.read(appUpdateProvider.notifier).download();
      final ready = statusOf(c) as UpdateReady;

      await c.read(appUpdateProvider.notifier).dismiss();

      expect(ready.file.existsSync(), isTrue);
      expect(statusOf(c), isA<UpdateReady>());
      expect(c.read(appUpdateProvider.notifier).isDismissed, isTrue);
    });
  });

  group('dismiss', () {
    test('persists the tag and marks the release dismissed', () async {
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await containerWith(service);
      await c.read(appUpdateProvider.notifier).check();

      expect(c.read(appUpdateProvider.notifier).isDismissed, isFalse);
      await c.read(appUpdateProvider.notifier).dismiss();

      expect(
        c.read(sharedPreferencesProvider).getString(kUpdateDismissedTag),
        'v0.2.0+12',
      );
      expect(c.read(updateDismissedTagProvider), 'v0.2.0+12');
      expect(c.read(appUpdateProvider.notifier).isDismissed, isTrue);
    });

    test('a newer release is not dismissed by an older dismissal', () async {
      SharedPreferences.setMockInitialValues({
        kUpdateDismissedTag: 'v0.1.5+11',
      });
      final service = FakeUpdateService(
        release: releaseOf(const ReleaseVersion(0, 2, 0, 12)),
      );
      final c = await containerWith(service);
      await c.read(appUpdateProvider.notifier).check();

      expect(c.read(appUpdateProvider.notifier).isDismissed, isFalse);
    });
  });
}
