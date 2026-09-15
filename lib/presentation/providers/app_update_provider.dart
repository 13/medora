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
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/app_config_provider.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// When the last successful check ran, as an ISO-8601 UTC timestamp.
const kUpdateLastCheckAt = 'update.last_check_at';

/// The release tag the user dismissed on the Home banner.
const kUpdateDismissedTag = 'update.dismissed_tag';

/// The release tag last handed to Android's package installer.
///
/// Written before the installer opens and cleared once the running build is
/// that release (or newer): an installer the user backed out of leaves it in
/// place, which is how the app knows the APK on disk is still worth offering.
const kUpdateInstallingTag = 'update.installing_tag';

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
  return ReleaseVersion.fromPackageInfo(info.version, info.buildNumber);
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

  /// Which download owns the state.
  ///
  /// [download] takes the next number for itself and [cancelDownload] burns
  /// the current one, so "was I cancelled?" and "am I still the download the
  /// user is waiting for?" are the same question - and a download started
  /// while an older one is still unwinding cannot be answered by that older
  /// one. Nothing resets it: a generation is spent once and never returns.
  int _downloadGeneration = 0;

  /// The release the current generation is downloading, so cancelling can put
  /// it back on offer - [UpdateDownloading] does not carry the asset. Set by
  /// [download] beside the generation it belongs to.
  UpdateAvailable? _downloadTarget;

  @override
  Future<UpdateStatus> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return await _reconcileInstall() ?? const UpdateUnknown();
  }

  /// Settles what happened to the last install that was started.
  ///
  /// Returns null when there is nothing to settle - no install was started,
  /// or the running build already is that release, in which case the APK is
  /// deleted and the pref cleared. Returns [UpdateReady] when the release is
  /// still not installed and the verified APK is still on disk: the user
  /// backed out of Android's installer, so the sheet offers Install again.
  Future<UpdateReady?> _reconcileInstall() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final tag = prefs.getString(kUpdateInstallingTag);
    if (tag == null) return null;
    final dir = await ref.read(updateDownloadDirProvider.future);
    final pending = ReleaseInfo.forTag(tag);
    final current = await ref.read(currentReleaseVersionProvider.future);
    final apk = AppUpdateService.downloadedApk(dir);
    if (pending == null ||
        apk == null ||
        !pending.version.isNewerThan(current)) {
      AppUpdateService.clearDownloads(dir);
      await prefs.remove(kUpdateInstallingTag);
      return null;
    }
    return UpdateReady(pending, apk);
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
  /// satisfied by trying harder. A download in flight, and an APK this
  /// session downloaded and verified, are never clobbered by a check.
  ///
  /// An install that was started before and backed out of is not in that
  /// group. It is reported first, so the sheet can offer Install again right
  /// away, but the check goes on: `update.installing_tag` only records that
  /// the installer was opened once, and a release newer than the APK on disk
  /// has to be able to take over. Nothing newer means the pending install
  /// stands - including when GitHub cannot be reached at all.
  Future<void> check({bool force = false}) async {
    final pending = await _reconcileInstall();
    if (pending != null) _emit(pending);

    final current = state.value;
    if (current is UpdateDownloading) return;
    if (pending == null && current is UpdateReady) return;
    if (!_enabled) {
      if (pending == null) _emit(const UpdateUnknown());
      return;
    }
    if (!ref.read(updateIsOnlineProvider)()) return;
    if (!force && !_intervalElapsed()) return;

    // Not while a pending install is showing: "checking" would replace the
    // Install offer with a spinner, and a failed check has to leave it up.
    if (pending == null) _emit(const UpdateChecking());
    final service = ref.read(appUpdateServiceProvider);
    try {
      final release = await service.checkLatest();
      await ref
          .read(sharedPreferencesProvider)
          .setString(
            kUpdateLastCheckAt,
            ref.read(nowProvider)().toUtc().toIso8601String(),
          );
      if (pending != null) {
        if (!release.version.isNewerThan(pending.release.version)) return;
        // The APK on disk has been overtaken: it will never be installed,
        // so the pin and the file both go before the newer one is offered.
        await _clearPendingInstall();
      }
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
      // A pending install survives a check that could not run: the APK is
      // still there and the error says nothing about it.
      if (pending != null) return;
      _emit(UpdateFailed(error));
    }
  }

  /// Forgets the install that was started: the pin and the APK behind it.
  Future<void> _clearPendingInstall() async {
    final dir = await ref.read(updateDownloadDirProvider.future);
    AppUpdateService.clearDownloads(dir);
    await ref.read(sharedPreferencesProvider).remove(kUpdateInstallingTag);
  }

  /// Downloads and verifies the available APK.
  ///
  /// Every step reports only while this call is still the current
  /// generation: a cancelled download, or one a newer download replaced,
  /// unwinds in silence rather than writing progress over what took its
  /// place.
  Future<void> download() async {
    final status = state.value;
    if (status is! UpdateAvailable) return;
    final gen = ++_downloadGeneration;
    _downloadTarget = status;
    _emit(UpdateDownloading(status.release, 0));
    try {
      final dir = await ref.read(updateDownloadDirProvider.future);
      final file = await ref
          .read(appUpdateServiceProvider)
          .download(
            status.release,
            status.asset,
            dir,
            onProgress: (progress) {
              if (gen != _downloadGeneration) return;
              _emit(UpdateDownloading(status.release, progress));
            },
            isCancelled: () => gen != _downloadGeneration,
          );
      if (gen != _downloadGeneration) {
        // A cancel that arrived while the last chunks were being verified:
        // the APK finished anyway and nobody asked for it. A download that
        // took over instead clears `updates/` itself before it writes, so
        // only tidy up when none is running.
        if (state.value is! UpdateDownloading) {
          AppUpdateService.clearDownloads(dir);
        }
        return;
      }
      _emit(UpdateReady(status.release, file));
    } on UpdateException catch (error) {
      // Cancelling is not a failure and [cancelDownload] already said so.
      if (error.kind == UpdateErrorKind.cancelled) return;
      if (gen != _downloadGeneration) return;
      _emit(UpdateFailed(error));
    }
  }

  /// Stops a download in flight and offers it again.
  ///
  /// The state goes back to [UpdateAvailable] at once - the user asked for
  /// the progress bar to go away - while the service unwinds the stream and
  /// removes the partial file on its own schedule. Burning the generation is
  /// what tells that download it no longer owns anything.
  void cancelDownload() {
    final status = state.value;
    if (status is! UpdateDownloading) return;
    _downloadGeneration++;
    final target = _downloadTarget;
    if (target != null) _emit(target);
  }

  /// Hands the verified APK to Android's package installer.
  Future<void> install() async {
    final status = state.value;
    if (status is! UpdateReady) return;
    try {
      // Written first: the installer replaces this process, so anything
      // recorded after the hand-over would never be written at all. A write
      // that fails therefore stops the install - handing the APK over with
      // no record of it would strand the pref on the previous release.
      await ref
          .read(sharedPreferencesProvider)
          .setString(kUpdateInstallingTag, status.release.tag);
    } catch (e) {
      _emit(
        UpdateFailed(
          UpdateException(
            UpdateErrorKind.io,
            'Could not record the pending install: $e',
          ),
        ),
      );
      return;
    }
    try {
      await ref.read(appUpdateServiceProvider).install(status.file);
    } on UpdateException catch (error) {
      _emit(UpdateFailed(error));
    }
  }

  /// Hides the Home banner for the release the status refers to.
  ///
  /// "Later" on an install that was started before and backed out of means
  /// more than hiding a banner: the pin and the APK go too, so the next check
  /// starts from whatever GitHub has rather than from a file the user has now
  /// turned down twice.
  Future<void> dismiss() async {
    final status = state.value;
    final tag = updateTagOf(status);
    if (tag == null) return;
    final pinned = ref
        .read(sharedPreferencesProvider)
        .getString(kUpdateInstallingTag);
    if (status is UpdateReady && pinned == tag) {
      await _clearPendingInstall();
      _emit(const UpdateUnknown());
    }
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
