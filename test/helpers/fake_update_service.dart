import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:medora/core/app_config.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// An [AppUpdateService] that answers from memory - no HTTP, no plugins.
class FakeUpdateService extends AppUpdateService {
  FakeUpdateService({
    this.release,
    this.error,
    this.downloadError,
    this._asset,
    this.hasAsset = true,
  }) : super(repo: 'acme/medora');

  final ReleaseInfo? release;
  final UpdateException? error;
  final UpdateException? downloadError;
  final ReleaseAsset? _asset;
  final bool hasAsset;

  int checks = 0;
  final List<File> installed = <File>[];

  @override
  Future<ReleaseInfo> checkLatest() async {
    checks++;
    final failure = error;
    if (failure != null) throw failure;
    return release!;
  }

  @override
  Future<ReleaseAsset?> pickAssetForDevice(ReleaseInfo release) async =>
      hasAsset ? (_asset ?? release.assets.first) : null;

  @override
  Future<File> download(
    ReleaseInfo release,
    ReleaseAsset asset,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0);
    onProgress?.call(0.5);
    final failure = downloadError;
    if (failure != null) throw failure;
    onProgress?.call(1);
    return File(p.join(dir.path, asset.name))..writeAsBytesSync(const [1, 2]);
  }

  @override
  Future<void> install(File apk) async => installed.add(apk);
}

/// The running build in update tests.
const fakeCurrentVersion = ReleaseVersion(0, 1, 0, 9);

ReleaseAsset fakeApkAsset(String name) => ReleaseAsset(
  name: name,
  size: 4,
  url: Uri.parse('https://example.test/$name'),
);

ReleaseInfo fakeRelease(ReleaseVersion version) => ReleaseInfo(
  tag: 'v${version.version}+${version.build}',
  version: version,
  title: 'Medora ${version.label}',
  notes: 'Fixed the thing.',
  publishedAt: DateTime.utc(2026, 3),
  assets: [
    fakeApkAsset('medora-${version.version}-${version.build}-arm64-v8a.apk'),
  ],
);

/// Everything [appUpdateProvider] needs, with no plugin or network in reach.
///
/// [isOnline], when given, replaces the fixed [online] flag - pass a closure
/// over a mutable local so a single test can flip connectivity mid-run
/// without re-overriding the provider (which a `ProviderContainer` forbids).
Future<List<Override>> updateOverrides({
  required AppUpdateService service,
  required Directory downloadDir,
  required DateTime Function() now,
  PlatformCapabilities caps = PlatformCapabilities.mobile,
  String repo = 'acme/medora',
  bool online = true,
  bool Function()? isOnline,
  ReleaseVersion current = fakeCurrentVersion,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return <Override>[
    sharedPreferencesProvider.overrideWithValue(prefs),
    platformCapabilitiesProvider.overrideWithValue(caps),
    appConfigProvider.overrideWithValue(
      AppConfig(supabaseUrl: '', supabaseAnonKey: '', updateRepo: repo),
    ),
    appUpdateServiceProvider.overrideWithValue(service),
    currentReleaseVersionProvider.overrideWith((ref) async => current),
    updateDownloadDirProvider.overrideWith((ref) async => downloadDir),
    updateIsOnlineProvider.overrideWithValue(isOnline ?? () => online),
    nowProvider.overrideWithValue(now),
  ];
}
