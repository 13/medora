/// Medora - In-app update state.
///
/// [AppUpdateNotifier] is the only thing that drives [AppUpdateService]: it
/// decides whether a check is allowed at all (Android, a configured repo, and
/// a connection), throttles automatic checks to once a day across restarts
/// through the `update.last_check_at` pref, and turns each step into a
/// [UpdateStatus] the Settings tile, the update sheet and the Home banner
/// render.
///
/// The check is deliberately silent about problems it cannot fix: offline or
/// unsupported builds keep whatever state they had instead of showing an
/// error the user can do nothing about.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// When the last successful check ran, as an ISO-8601 UTC timestamp.
const kUpdateLastCheckAt = 'update.last_check_at';

/// The release tag the user dismissed on the Home banner.
const kUpdateDismissedTag = 'update.dismissed_tag';

// ── State ────────────────────────────────────────────────────

/// What the app knows about a newer release right now.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// Nothing has been checked (yet), or this build never checks.
class UpdateUnknown extends UpdateStatus {
  const UpdateUnknown();
}

/// A check is in flight.
class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

/// The newest release is not newer than [current].
class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate(this.current);

  final ReleaseVersion current;
}

/// A newer release exists and carries an APK this device can install.
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.release, this.asset);

  final ReleaseInfo release;
  final ReleaseAsset asset;
}

/// The APK is being fetched; [progress] runs 0..1 and only reaches 1 once
/// the service verified size and checksum.
class UpdateDownloading extends UpdateStatus {
  const UpdateDownloading(this.release, this.progress);

  final ReleaseInfo release;
  final double progress;
}

/// A verified APK is on disk, waiting for the system installer.
class UpdateReady extends UpdateStatus {
  const UpdateReady(this.release, this.file);

  final ReleaseInfo release;
  final File file;
}

/// A check, download or install step failed.
class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.error);

  final UpdateException error;
}

/// The release tag carried by [status], when it refers to one.
String? updateTagOf(UpdateStatus? status) => switch (status) {
  UpdateAvailable(:final release) => release.tag,
  UpdateDownloading(:final release) => release.tag,
  UpdateReady(:final release) => release.tag,
  _ => null,
};

// ── Seams ────────────────────────────────────────────────────

/// Build-time configuration; overridden in tests that need a specific repo.
final appConfigProvider = Provider<AppConfig>(
  (_) => AppConfig.fromEnvironment(),
);

/// The one [AppUpdateService] instance; it owns an HTTP client, so it is
/// closed with the scope.
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final service = AppUpdateService(
    repo: ref.watch(appConfigProvider).updateRepo,
  );
  ref.onDispose(service.close);
  return service;
});

/// The running build as a [ReleaseVersion], from `package_info_plus`.
final currentReleaseVersionProvider = FutureProvider<ReleaseVersion>((
  ref,
) async {
  final info = await PackageInfo.fromPlatform();
  return ReleaseVersion.parse('${info.version}+${info.buildNumber}') ??
      const ReleaseVersion(0, 0, 0, 0);
});

/// Where downloaded APKs land. Support (not documents): an update is a cache
/// the user never needs to see.
final updateDownloadDirProvider = FutureProvider<Directory>(
  (_) => getApplicationSupportDirectory(),
);

/// Connectivity seam, so tests can be offline without a plugin.
final updateIsOnlineProvider = Provider<bool Function()>(
  (_) =>
      () => ConnectivityService.instance.isOnline,
);

// ── Dismissal ────────────────────────────────────────────────

/// The release tag dismissed on the Home banner, or null.
///
/// Separate from [appUpdateProvider] on purpose: dismissing hides the banner
/// without changing what Settings reports about the release.
final updateDismissedTagProvider =
    NotifierProvider<UpdateDismissedTagNotifier, String?>(
      UpdateDismissedTagNotifier.new,
    );

class UpdateDismissedTagNotifier extends Notifier<String?> {
  @override
  String? build() =>
      ref.watch(sharedPreferencesProvider).getString(kUpdateDismissedTag);

  Future<void> set(String tag) async {
    state = tag;
    await ref
        .read(sharedPreferencesProvider)
        .setString(kUpdateDismissedTag, tag);
  }
}

// ── Notifier ─────────────────────────────────────────────────

final appUpdateProvider =
    AsyncNotifierProvider<AppUpdateNotifier, UpdateStatus>(
      AppUpdateNotifier.new,
    );

class AppUpdateNotifier extends AsyncNotifier<UpdateStatus> {
  /// How long an automatic check is suppressed after a successful one.
  static const checkInterval = Duration(hours: 24);

  bool _disposed = false;

  @override
  Future<UpdateStatus> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const UpdateUnknown();
  }

  /// True when this build may look for updates at all.
  bool get _enabled =>
      ref.read(platformCapabilitiesProvider).hasInAppUpdates &&
      ref.read(appConfigProvider).hasInAppUpdates;

  /// True when the user dismissed the release the current status refers to.
  bool get isDismissed {
    final tag = updateTagOf(state.value);
    return tag != null && ref.read(updateDismissedTagProvider) == tag;
  }

  /// Asks GitHub for the newest release.
  ///
  /// [force] is the Settings button: it skips the 24 h throttle but not the
  /// platform, configuration and connectivity gates - none of those can be
  /// satisfied by trying harder. A download already in flight (or a verified
  /// APK waiting to install) is never clobbered by a fresh check, forced or
  /// not.
  Future<void> check({bool force = false}) async {
    final current = state.value;
    if (current is UpdateDownloading || current is UpdateReady) return;
    if (!_enabled) {
      _emit(const UpdateUnknown());
      return;
    }
    if (!ref.read(updateIsOnlineProvider)()) return;
    if (!force && !_intervalElapsed()) return;

    _emit(const UpdateChecking());
    final service = ref.read(appUpdateServiceProvider);
    try {
      final release = await service.checkLatest();
      await ref
          .read(sharedPreferencesProvider)
          .setString(
            kUpdateLastCheckAt,
            ref.read(nowProvider)().toUtc().toIso8601String(),
          );
      final current = await ref.read(currentReleaseVersionProvider.future);
      if (!release.version.isNewerThan(current)) {
        _emit(UpdateUpToDate(current));
        return;
      }
      final asset = await service.pickAssetForDevice(release);
      if (asset == null) {
        _emit(
          UpdateFailed(
            UpdateException(
              UpdateErrorKind.noAsset,
              '${release.tag} has no APK for this device.',
            ),
          ),
        );
        return;
      }
      _emit(UpdateAvailable(release, asset));
    } on UpdateException catch (error) {
      _emit(UpdateFailed(error));
    }
  }

  /// Downloads and verifies the available APK.
  Future<void> download() async {
    final status = state.value;
    if (status is! UpdateAvailable) return;
    _emit(UpdateDownloading(status.release, 0));
    try {
      final dir = await ref.read(updateDownloadDirProvider.future);
      final file = await ref
          .read(appUpdateServiceProvider)
          .download(
            status.release,
            status.asset,
            dir,
            onProgress: (progress) =>
                _emit(UpdateDownloading(status.release, progress)),
          );
      _emit(UpdateReady(status.release, file));
    } on UpdateException catch (error) {
      _emit(UpdateFailed(error));
    }
  }

  /// Hands the verified APK to Android's package installer.
  Future<void> install() async {
    final status = state.value;
    if (status is! UpdateReady) return;
    try {
      await ref.read(appUpdateServiceProvider).install(status.file);
    } on UpdateException catch (error) {
      _emit(UpdateFailed(error));
    }
  }

  /// Hides the Home banner for the release the status refers to.
  Future<void> dismiss() async {
    final tag = updateTagOf(state.value);
    if (tag == null) return;
    await ref.read(updateDismissedTagProvider.notifier).set(tag);
  }

  bool _intervalElapsed() {
    final raw = ref
        .read(sharedPreferencesProvider)
        .getString(kUpdateLastCheckAt);
    final last = raw == null ? null : DateTime.tryParse(raw);
    if (last == null) return true;
    return ref.read(nowProvider)().toUtc().difference(last.toUtc()) >=
        checkInterval;
  }

  /// A download can outlive its scope (the user leaves the screen); writing
  /// to a disposed notifier would throw.
  void _emit(UpdateStatus status) {
    if (_disposed) return;
    state = AsyncData(status);
  }
}
