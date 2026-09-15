/// Medora - In-app updates from GitHub Releases (Android only).
///
/// Pure Dart over `package:http` so every step is testable with `MockClient`:
/// ask the GitHub API for the latest release, compare its version with the
/// running build, pick the APK for the device's ABI, stream it to disk while
/// hashing it, verify size and SHA-256, then hand the file to the system
/// installer through the injectable [AppUpdateService.new] `installer` seam.
///
/// Nothing here imports Flutter widgets; the platform plugins used by the
/// default seams (`device_info_plus`, `open_filex`) are only touched when the
/// caller does not inject its own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// A `<major>.<minor>.<patch>+<build>` release version.
///
/// The build number is the authority for "newer" (it increases on every
/// release); semver only breaks ties between equal builds.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, this.build);

  static final RegExp _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$');

  /// Parses `v0.1.0+10`, `0.1.0+10` or `0.1.0` (build 0); null when unusable.
  static ReleaseVersion? parse(String tagOrVersion) {
    final match = _pattern.firstMatch(tagOrVersion.trim());
    if (match == null) return null;
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4) ?? '0'),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final int build;

  /// `0.1.0`
  String get version => '$major.$minor.$patch';

  /// `0.1.0 (10)` - what the UI shows.
  String get label => '$version ($build)';

  bool isNewerThan(ReleaseVersion other) => compareTo(other) > 0;

  @override
  int compareTo(ReleaseVersion other) {
    if (build != other.build) return build.compareTo(other.build);
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => 'ReleaseVersion($label)';
}

/// One downloadable file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
  });

  /// Parses one entry of the GitHub `assets` array.
  factory ReleaseAsset.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || url is! String) {
      throw const FormatException('an asset is missing name or download url');
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null) {
      throw FormatException('asset "$name" has an unusable url');
    }
    final size = json['size'];
    return ReleaseAsset(name: name, size: size is int ? size : 0, url: parsed);
  }

  final String name;

  /// Bytes as reported by GitHub; 0 when unknown (then the size check is off).
  final int size;
  final Uri url;

  bool get isApk => name.toLowerCase().endsWith('.apk');

  @override
  String toString() => 'ReleaseAsset($name, $size bytes)';
}

/// The `/releases/latest` payload, reduced to what the app needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.publishedAt,
    required this.assets,
  });

  factory ReleaseInfo.fromJson(Map<String, Object?> json) {
    final tag = json['tag_name'];
    if (tag is! String) {
      throw const FormatException('the release has no tag_name');
    }
    final version = ReleaseVersion.parse(tag);
    if (version == null) {
      throw FormatException('tag "$tag" is not a v<version>+<build> tag');
    }
    final rawAssets = json['assets'];
    final assets = <ReleaseAsset>[
      if (rawAssets is List)
        for (final asset in rawAssets)
          if (asset is Map<String, Object?>) ReleaseAsset.fromJson(asset),
    ];
    final name = json['name'];
    final body = json['body'];
    final published = json['published_at'];
    return ReleaseInfo(
      tag: tag,
      version: version,
      title: name is String && name.trim().isNotEmpty
          ? name
          : 'Medora ${version.label}',
      notes: body is String ? body : '',
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      assets: assets,
    );
  }

  final String tag;
  final ReleaseVersion version;
  final String title;
  final String notes;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  /// The `SHA256SUMS.txt` asset, when the release carries one.
  ReleaseAsset? get checksums {
    for (final asset in assets) {
      if (asset.name == AppUpdateService.checksumsFileName) return asset;
    }
    return null;
  }

  @override
  String toString() => 'ReleaseInfo($tag, ${assets.length} assets)';
}

/// Why an update step failed - the UI maps these to messages.
enum UpdateErrorKind {
  /// The GitHub API or the download could not be reached.
  network,

  /// The response was not the release JSON we expect.
  parse,

  /// The release carries no APK this device can install.
  noAsset,

  /// The downloaded bytes do not match `SHA256SUMS.txt`.
  checksum,

  /// Writing to or reading from disk failed, or the file is the wrong size.
  io,
}

class UpdateException implements Exception {
  const UpdateException(this.kind, this.message);

  final UpdateErrorKind kind;
  final String message;

  @override
  String toString() => 'UpdateException(${kind.name}: $message)';
}

/// Finds, downloads, verifies and installs Medora releases from GitHub.
class AppUpdateService {
  AppUpdateService({
    required this.repo,
    http.Client? client,
    Future<List<String>> Function()? supportedAbis,
    Future<void> Function(String path)? installer,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _supportedAbis = supportedAbis ?? _deviceAbis,
       _installer = installer ?? _openWithSystemInstaller;

  /// Folder under the caller's directory that holds the downloaded APK.
  static const updatesFolder = 'updates';
  static const checksumsFileName = 'SHA256SUMS.txt';
  static const userAgent = 'medora';
  static const apkMimeType = 'application/vnd.android.package-archive';
  static const _universalSuffix = '-universal.apk';

  /// `<owner>/<name>` on GitHub, from `AppConfig.updateRepo`.
  final String repo;

  final http.Client _client;
  final bool _ownsClient;
  final Future<List<String>> Function() _supportedAbis;
  final Future<void> Function(String path) _installer;

  /// Closes the client when this service created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// The newest published release (GitHub's `/latest` skips drafts and
  /// pre-releases for us).
  Future<ReleaseInfo> checkLatest() async {
    final uri = Uri.https('api.github.com', '/repos/$repo/releases/latest');
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': userAgent,
        },
      );
    } on Exception catch (error) {
      throw UpdateException(
        UpdateErrorKind.network,
        'Could not reach GitHub: $error',
      );
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        UpdateErrorKind.network,
        'GitHub answered HTTP ${response.statusCode} for $uri.',
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('the release payload is not an object');
      }
      return ReleaseInfo.fromJson(decoded);
    } on FormatException catch (error) {
      throw UpdateException(
        UpdateErrorKind.parse,
        'Unexpected release payload: ${error.message}',
      );
    }
  }

  /// The APK for the first of [abis] the release was built for, else the
  /// universal APK, else null.
  ReleaseAsset? pickAsset(ReleaseInfo release, List<String> abis) {
    for (final abi in abis) {
      final suffix = '-$abi.apk';
      for (final asset in release.assets) {
        if (asset.isApk && asset.name.endsWith(suffix)) return asset;
      }
    }
    for (final asset in release.assets) {
      if (asset.name.endsWith(_universalSuffix)) return asset;
    }
    return null;
  }

  /// [pickAsset] for the ABIs this device reports.
  Future<ReleaseAsset?> pickAssetForDevice(ReleaseInfo release) async =>
      pickAsset(release, await _supportedAbis());

  /// Streams [asset] to `<dir>/updates/<name>`, hashing as it goes.
  ///
  /// Older files in `updates/` are removed first (one update at a time is
  /// enough, and APKs are large). The finished file must match the size GitHub
  /// reported and, when the release carries `SHA256SUMS.txt`, its sha256 line;
  /// on any mismatch the file is deleted before the error is thrown.
  Future<File> download(
    ReleaseInfo release,
    ReleaseAsset asset,
    Directory dir, {
    void Function(double progress)? onProgress,
  }) async {
    final target = Directory(p.join(dir.path, updatesFolder));
    final File file;
    try {
      await target.create(recursive: true);
      _clearFolder(target);
      file = File(p.join(target.path, asset.name));
    } on FileSystemException catch (error) {
      throw UpdateException(
        UpdateErrorKind.io,
        'Could not prepare ${target.path}: ${error.message}',
      );
    }

    Digest? digest;
    final hasher = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (digests) => digest = digests.single,
      ),
    );
    final sink = file.openWrite();
    var received = 0;
    onProgress?.call(0);
    try {
      final response = await _client.send(http.Request('GET', asset.url));
      if (response.statusCode != 200) {
        throw UpdateException(
          UpdateErrorKind.network,
          'Download answered HTTP ${response.statusCode}.',
        );
      }
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (asset.size > 0) {
          onProgress?.call((received / asset.size).clamp(0, 1));
        }
      }
      await sink.flush();
    } on UpdateException {
      await sink.close();
      _deleteQuietly(file);
      rethrow;
    } on Exception catch (error) {
      await sink.close();
      _deleteQuietly(file);
      throw UpdateException(
        error is FileSystemException
            ? UpdateErrorKind.io
            : UpdateErrorKind.network,
        'Download of ${asset.name} failed: $error',
      );
    }
    await sink.close();
    hasher.close();

    if (asset.size > 0 && received != asset.size) {
      _deleteQuietly(file);
      throw UpdateException(
        UpdateErrorKind.io,
        'Downloaded $received bytes but the release lists ${asset.size}.',
      );
    }

    final sums = release.checksums;
    if (sums != null) {
      final expected = await _expectedChecksum(sums, asset.name, file);
      if (expected != digest.toString()) {
        _deleteQuietly(file);
        throw UpdateException(
          UpdateErrorKind.checksum,
          '${asset.name} does not match its SHA256SUMS.txt entry.',
        );
      }
    }

    onProgress?.call(1);
    return file;
  }

  /// Hands the APK to Android's package installer.
  Future<void> install(File apk) async {
    if (!apk.existsSync()) {
      throw UpdateException(
        UpdateErrorKind.io,
        'The downloaded update is gone: ${apk.path}',
      );
    }
    await _installer(apk.path);
  }

  /// The sha256 hex for [name] from the release's `SHA256SUMS.txt`.
  ///
  /// An unreachable or incomplete checksum file counts as a failed
  /// verification: an APK we cannot verify is never installed.
  Future<String> _expectedChecksum(
    ReleaseAsset sums,
    String name,
    File downloaded,
  ) async {
    final http.Response response;
    try {
      response = await _client.get(
        sums.url,
        headers: const {'User-Agent': userAgent},
      );
    } on Exception catch (error) {
      _deleteQuietly(downloaded);
      throw UpdateException(
        UpdateErrorKind.checksum,
        'Could not fetch $checksumsFileName: $error',
      );
    }
    if (response.statusCode != 200) {
      _deleteQuietly(downloaded);
      throw UpdateException(
        UpdateErrorKind.checksum,
        '$checksumsFileName answered HTTP ${response.statusCode}.',
      );
    }
    for (final line in const LineSplitter().convert(response.body)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      // sha256sum format: `<hex>  <name>`, `*` marks binary mode.
      final entry = parts.last.replaceFirst(RegExp(r'^\*'), '');
      if (entry == name) return parts.first.toLowerCase();
    }
    _deleteQuietly(downloaded);
    throw UpdateException(
      UpdateErrorKind.checksum,
      '$checksumsFileName has no line for $name.',
    );
  }

  static void _clearFolder(Directory dir) {
    for (final entity in dir.listSync()) {
      try {
        entity.deleteSync(recursive: true);
      } on FileSystemException {
        // A leftover we cannot remove must not stop the new download.
      }
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Nothing useful to do; the folder is cleared before the next download.
    }
  }

  /// Default ABI seam - the device's ABIs, most preferred first.
  static Future<List<String>> _deviceAbis() async {
    if (!Platform.isAndroid) return const <String>[];
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis;
  }

  /// Default installer seam - Android shows the system package installer.
  static Future<void> _openWithSystemInstaller(String path) async {
    final result = await OpenFilex.open(path, type: apkMimeType);
    if (result.type != ResultType.done) {
      throw UpdateException(
        UpdateErrorKind.io,
        'Could not start the installer: ${result.message}',
      );
    }
  }
}
