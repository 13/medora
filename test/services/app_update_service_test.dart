import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:path/path.dart' as p;

const _repo = '13/medora';
const _latestUrl = 'https://api.github.com/repos/13/medora/releases/latest';

String _fixture() =>
    File(p.join('test', 'fixtures', 'github_release.json')).readAsStringSync();

/// A client that answers the release endpoint with the fixture and fails on
/// anything else, so an unexpected request shows up as a test failure.
MockClient _releaseClient({
  List<http.Request>? seen,
  int status = 200,
  String? body,
}) {
  return MockClient((request) async {
    seen?.add(request);
    if (request.url.toString() == _latestUrl) {
      return http.Response(
        body ?? _fixture(),
        status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('unexpected ${request.url}', 404);
  });
}

Future<ReleaseInfo> _latest(http.Client client) =>
    AppUpdateService(repo: _repo, client: client).checkLatest();

void main() {
  group('ReleaseVersion.parse', () {
    test('accepts a tag, a version with a build and a bare version', () {
      expect(
        ReleaseVersion.parse('v0.1.0+10'),
        const ReleaseVersion(0, 1, 0, 10),
      );
      expect(
        ReleaseVersion.parse('0.1.0+10'),
        const ReleaseVersion(0, 1, 0, 10),
      );
      expect(ReleaseVersion.parse('0.1.0'), const ReleaseVersion(0, 1, 0, 0));
      expect(
        ReleaseVersion.parse('  v12.34.56+789  '),
        const ReleaseVersion(12, 34, 56, 789),
      );
    });

    test('returns null for anything else', () {
      for (final input in <String>[
        'garbage',
        '',
        'v1.2',
        '1.2.3.4',
        'v1.2.3+',
        '1.2.3+beta',
        'vx.y.z',
      ]) {
        expect(ReleaseVersion.parse(input), isNull, reason: 'parsed "$input"');
      }
    });
  });

  group('ReleaseVersion.fromPackageInfo', () {
    test('strips the split-per-abi version code offset', () {
      // arm64-v8a split APK of 0.2.0+12 reports version code 2012.
      expect(ReleaseVersion.releaseBuildOf('2012'), 12);
      expect(ReleaseVersion.releaseBuildOf('1012'), 12); // armeabi-v7a
      expect(ReleaseVersion.releaseBuildOf('4012'), 12); // x86_64
      expect(ReleaseVersion.releaseBuildOf('12'), 12); // universal APK
      expect(ReleaseVersion.releaseBuildOf(''), 0);
      expect(ReleaseVersion.releaseBuildOf('abc'), 0);
      expect(
        ReleaseVersion.fromPackageInfo('0.2.0', '2012'),
        const ReleaseVersion(0, 2, 0, 12),
      );
    });

    test('an installed split APK sees the next release as newer', () {
      final installed = ReleaseVersion.fromPackageInfo('0.2.0', '2012');
      final latest = ReleaseVersion.parse('v0.2.1+13')!;
      expect(latest.isNewerThan(installed), isTrue);
      expect(installed.isNewerThan(latest), isFalse);
      // The same release is not offered again.
      final same = ReleaseVersion.fromPackageInfo('0.2.1', '2013');
      expect(latest.isNewerThan(same), isFalse);
    });
  });

  group('ReleaseVersion comparison', () {
    test('semver decides which release is newer', () {
      final a = ReleaseVersion.parse('1.3.0+4')!;
      final b = ReleaseVersion.parse('1.2.9+4')!;
      expect(a.isNewerThan(b), isTrue);
      expect(b.isNewerThan(a), isFalse);
      expect(
        ReleaseVersion.parse(
          '1.2.10+4',
        )!.isNewerThan(ReleaseVersion.parse('1.2.9+4')!),
        isTrue,
      );
      // A higher semver wins even against a larger build number.
      expect(
        ReleaseVersion.parse(
          '0.2.1+13',
        )!.isNewerThan(ReleaseVersion.parse('0.2.0+2012')!),
        isTrue,
      );
    });

    test('the build number breaks ties between equal semvers', () {
      final a = ReleaseVersion.parse('v1.2.3+4')!;
      final b = ReleaseVersion.parse('1.2.3+5')!;
      expect(b.isNewerThan(a), isTrue);
      expect(a.isNewerThan(b), isFalse);
    });

    test('an identical version is not newer', () {
      final a = ReleaseVersion.parse('v0.1.0+10')!;
      final b = ReleaseVersion.parse('0.1.0+10')!;
      expect(a.isNewerThan(b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.compareTo(b), 0);
    });

    test('label and version render for the UI', () {
      final v = ReleaseVersion.parse('v0.1.0+10')!;
      expect(v.label, '0.1.0 (10)');
      expect(v.version, '0.1.0');
    });

    test('sorts oldest first', () {
      final versions = <ReleaseVersion>[
        ReleaseVersion.parse('1.0.0+3')!,
        ReleaseVersion.parse('0.9.0+1')!,
        ReleaseVersion.parse('2.0.0+2')!,
      ]..sort();
      expect(versions.map((v) => v.label).toList(), <String>[
        '0.9.0 (1)',
        '1.0.0 (3)',
        '2.0.0 (2)',
      ]);
    });
  });

  group('checkLatest', () {
    test('parses the GitHub payload', () async {
      final release = await _latest(_releaseClient());
      expect(release.tag, 'v0.1.0+10');
      expect(release.version, const ReleaseVersion(0, 1, 0, 10));
      expect(release.title, 'Medora 0.1.0 (10)');
      expect(release.notes, contains('Offline-first sync'));
      expect(release.publishedAt, DateTime.utc(2026, 9, 14, 18, 9, 44));
      expect(release.assets.length, 6);
      final apk = release.assets.first;
      expect(apk.name, 'medora-0.1.0-10-arm64-v8a.apk');
      expect(apk.size, 28451234);
      expect(apk.url.toString(), endsWith('medora-0.1.0-10-arm64-v8a.apk'));
      expect(release.checksums?.name, 'SHA256SUMS.txt');
    });

    test('sends the GitHub Accept and User-Agent headers', () async {
      final seen = <http.Request>[];
      await _latest(_releaseClient(seen: seen));
      expect(seen, hasLength(1));
      expect(seen.single.url.toString(), _latestUrl);
      expect(seen.single.headers['Accept'], 'application/vnd.github+json');
      expect(seen.single.headers['User-Agent'], 'medora');
    });

    test('404 is a network error', () async {
      await expectLater(
        _latest(_releaseClient(status: 404, body: '{"message":"Not Found"}')),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.network,
          ),
        ),
      );
    });

    test('a transport failure is a network error', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('connection closed'),
      );
      await expectLater(
        _latest(client),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.network,
          ),
        ),
      );
    });

    test('malformed JSON is a parse error', () async {
      await expectLater(
        _latest(_releaseClient(body: '{not json')),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.parse,
          ),
        ),
      );
    });

    test('an unusable tag_name is a parse error', () async {
      await expectLater(
        _latest(_releaseClient(body: '{"tag_name":"nightly","assets":[]}')),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.parse,
          ),
        ),
      );
    });
  });

  group('pickAsset', () {
    late AppUpdateService service;
    late ReleaseInfo release;

    setUp(() async {
      service = AppUpdateService(repo: _repo, client: _releaseClient());
      release = await service.checkLatest();
    });

    test('takes the first matching ABI in device order', () {
      expect(
        service.pickAsset(release, const ['arm64-v8a', 'armeabi-v7a'])?.name,
        'medora-0.1.0-10-arm64-v8a.apk',
      );
      expect(
        service.pickAsset(release, const ['armeabi-v7a', 'arm64-v8a'])?.name,
        'medora-0.1.0-10-armeabi-v7a.apk',
      );
    });

    test('x86 has no build of its own and falls back to universal', () {
      expect(
        service.pickAsset(release, const ['x86'])?.name,
        'medora-0.1.0-10-universal.apk',
      );
      expect(
        service.pickAsset(release, const [])?.name,
        'medora-0.1.0-10-universal.apk',
      );
    });

    test('returns null when the release carries no APK', () async {
      final bare = await _latest(
        _releaseClient(
          body: jsonEncode(<String, Object?>{
            'tag_name': 'v0.1.0+10',
            'assets': <Object?>[
              <String, Object?>{
                'name': 'medora-0.1.0-10.aab',
                'size': 1,
                'browser_download_url': 'https://example.test/a.aab',
              },
            ],
          }),
        ),
      );
      expect(service.pickAsset(bare, const ['arm64-v8a']), isNull);
    });

    test('pickAssetForDevice uses the injected ABI seam', () async {
      final device = AppUpdateService(
        repo: _repo,
        client: _releaseClient(),
        supportedAbis: () async => const ['armeabi-v7a'],
      );
      expect(
        (await device.pickAssetForDevice(release))?.name,
        'medora-0.1.0-10-armeabi-v7a.apk',
      );
    });
  });

  group('download', () {
    late Directory root;
    final payload = List<int>.generate(4096, (i) => i % 256);
    late String digest;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('medora_update_');
      digest = sha256.convert(payload).toString();
    });
    tearDown(() => root.delete(recursive: true));

    /// A release whose single APK asset is served by the mock client.
    ReleaseInfo releaseWith({required bool withChecksums, int? size}) {
      return ReleaseInfo(
        tag: 'v0.1.0+10',
        version: const ReleaseVersion(0, 1, 0, 10),
        title: 'Medora 0.1.0 (10)',
        notes: '',
        publishedAt: null,
        assets: <ReleaseAsset>[
          ReleaseAsset(
            name: 'medora-0.1.0-10-universal.apk',
            size: size ?? payload.length,
            url: Uri.parse(
              'https://example.test/medora-0.1.0-10-universal.apk',
            ),
          ),
          if (withChecksums)
            ReleaseAsset(
              name: 'SHA256SUMS.txt',
              size: 100,
              url: Uri.parse('https://example.test/SHA256SUMS.txt'),
            ),
        ],
      );
    }

    MockClient downloadClient({String? sums, List<int>? body}) {
      return MockClient((request) async {
        if (request.url.path.endsWith('SHA256SUMS.txt')) {
          if (sums == null) return http.Response('missing', 404);
          return http.Response(sums, 200);
        }
        return http.Response.bytes(body ?? payload, 200);
      });
    }

    String sumsFor(String hex) =>
        'deadbeef  medora-0.1.0-10.aab\n$hex  medora-0.1.0-10-universal.apk\n';

    test(
      'streams the asset into updates/ and reports progress to 1.0',
      () async {
        final service = AppUpdateService(
          repo: _repo,
          client: downloadClient(sums: sumsFor(digest)),
        );
        final release = releaseWith(withChecksums: true);
        final progress = <double>[];
        final file = await service.download(
          release,
          release.assets.first,
          root,
          onProgress: progress.add,
        );

        expect(
          file.path,
          p.join(root.path, 'updates', 'medora-0.1.0-10-universal.apk'),
        );
        expect(file.readAsBytesSync(), payload);
        expect(progress, isNotEmpty);
        expect(progress.last, 1.0);
        expect(progress.every((v) => v >= 0.0 && v <= 1.0), isTrue);
      },
    );

    test('works when the release has no SHA256SUMS.txt', () async {
      final service = AppUpdateService(repo: _repo, client: downloadClient());
      final release = releaseWith(withChecksums: false);
      final file = await service.download(release, release.assets.first, root);
      expect(file.existsSync(), isTrue);
    });

    test('a checksum mismatch deletes the file and reports checksum', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: downloadClient(sums: sumsFor('00' * 32)),
      );
      final release = releaseWith(withChecksums: true);
      await expectLater(
        service.download(release, release.assets.first, root),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.checksum,
          ),
        ),
      );
      expect(
        File(
          p.join(root.path, 'updates', 'medora-0.1.0-10-universal.apk'),
        ).existsSync(),
        isFalse,
      );
    });

    test('a checksum mismatch never reports 1.0 progress', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: downloadClient(sums: sumsFor('00' * 32)),
      );
      final release = releaseWith(withChecksums: true);
      final progress = <double>[];
      await expectLater(
        service.download(
          release,
          release.assets.first,
          root,
          onProgress: progress.add,
        ),
        throwsA(isA<UpdateException>()),
      );
      // 1.0 means "installable": it is only reported once size and checksum
      // verification passed.
      expect(progress, isNot(contains(1.0)));
      expect(progress.every((v) => v >= 0.0 && v <= 0.99), isTrue);
    });

    test('an unreadable SHA256SUMS.txt is a checksum failure', () async {
      final service = AppUpdateService(repo: _repo, client: downloadClient());
      final release = releaseWith(withChecksums: true);
      await expectLater(
        service.download(release, release.assets.first, root),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.checksum,
          ),
        ),
      );
    });

    test('a size mismatch is an io error and deletes the file', () async {
      final service = AppUpdateService(repo: _repo, client: downloadClient());
      final release = releaseWith(withChecksums: false, size: 999999);
      await expectLater(
        service.download(release, release.assets.first, root),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.io,
          ),
        ),
      );
      expect(
        File(
          p.join(root.path, 'updates', 'medora-0.1.0-10-universal.apk'),
        ).existsSync(),
        isFalse,
      );
    });

    test('a failed download is a network error', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: MockClient((_) async => http.Response('gone', 503)),
      );
      final release = releaseWith(withChecksums: false);
      await expectLater(
        service.download(release, release.assets.first, root),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.network,
          ),
        ),
      );
    });

    test('cancelling mid-stream deletes the partial file', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: downloadClient(sums: sumsFor(digest)),
      );
      final release = releaseWith(withChecksums: true);
      final progress = <double>[];

      await expectLater(
        service.download(
          release,
          release.assets.first,
          root,
          onProgress: progress.add,
          isCancelled: () => true,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.cancelled,
          ),
        ),
      );

      expect(
        File(
          p.join(root.path, 'updates', 'medora-0.1.0-10-universal.apk'),
        ).existsSync(),
        isFalse,
      );
      expect(progress, isNot(contains(1.0)));
    });

    test('a download nobody cancels still finishes', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: downloadClient(sums: sumsFor(digest)),
      );
      final release = releaseWith(withChecksums: true);

      final file = await service.download(
        release,
        release.assets.first,
        root,
        isCancelled: () => false,
      );

      expect(file.lengthSync(), payload.length);
    });

    test('older downloads are removed before the new one lands', () async {
      final updates = Directory(p.join(root.path, 'updates'))
        ..createSync(recursive: true);
      final stale = File(p.join(updates.path, 'medora-0.0.9-9-universal.apk'))
        ..writeAsBytesSync(const [1, 2, 3]);
      final service = AppUpdateService(repo: _repo, client: downloadClient());
      final release = releaseWith(withChecksums: false);

      await service.download(release, release.assets.first, root);

      expect(stale.existsSync(), isFalse);
      expect(updates.listSync().map((e) => p.basename(e.path)).toList(), [
        'medora-0.1.0-10-universal.apk',
      ]);
    });
  });

  group('downloads folder', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('medora_update_folder_');
    });
    tearDown(() => root.delete(recursive: true));

    Directory updatesDir() =>
        Directory(p.join(root.path, 'updates'))..createSync(recursive: true);

    test('clearDownloads empties updates/ and leaves the folder', () {
      final updates = updatesDir();
      File(p.join(updates.path, 'medora-0.2.0-12-universal.apk'))
        ..createSync()
        ..writeAsBytesSync(const [1, 2, 3]);
      File(p.join(updates.path, 'SHA256SUMS.txt')).writeAsStringSync('x');

      AppUpdateService.clearDownloads(root);

      expect(updates.existsSync(), isTrue);
      expect(updates.listSync(), isEmpty);
    });

    test('clearDownloads without an updates/ folder is not an error', () {
      AppUpdateService.clearDownloads(root);
      expect(Directory(p.join(root.path, 'updates')).existsSync(), isFalse);
    });

    test('downloadedApk finds the APK, ignoring anything else', () {
      final updates = updatesDir();
      File(p.join(updates.path, 'notes.txt')).writeAsStringSync('x');
      final apk = File(p.join(updates.path, 'medora-0.2.0-12-universal.apk'))
        ..writeAsBytesSync(const [1, 2, 3]);

      expect(AppUpdateService.downloadedApk(root)?.path, apk.path);
    });

    test('downloadedApk is null with no folder and with no APK', () {
      expect(AppUpdateService.downloadedApk(root), isNull);
      updatesDir();
      expect(AppUpdateService.downloadedApk(root), isNull);
    });
  });

  group('ReleaseInfo.forTag', () {
    test('describes a release the app only knows by tag', () {
      final release = ReleaseInfo.forTag('v0.2.0+12')!;

      expect(release.tag, 'v0.2.0+12');
      expect(release.version, const ReleaseVersion(0, 2, 0, 12));
      expect(release.title, 'Medora 0.2.0 (12)');
      expect(release.assets, isEmpty);
    });

    test('an unusable tag has no release', () {
      expect(ReleaseInfo.forTag('nightly'), isNull);
    });
  });

  group('install', () {
    test('hands the path to the injected installer', () async {
      final root = await Directory.systemTemp.createTemp('medora_install_');
      addTearDown(() => root.delete(recursive: true));
      final apk = File(p.join(root.path, 'medora.apk'))
        ..writeAsBytesSync(const [1, 2, 3]);
      final opened = <String>[];
      final service = AppUpdateService(
        repo: _repo,
        client: _releaseClient(),
        installer: (path) async => opened.add(path),
      );

      await service.install(apk);

      expect(opened, <String>[apk.path]);
    });

    test('a missing file is an io error', () async {
      final service = AppUpdateService(
        repo: _repo,
        client: _releaseClient(),
        installer: (_) async {},
      );
      await expectLater(
        service.install(File('/definitely/not/here/medora.apk')),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.kind,
            'kind',
            UpdateErrorKind.io,
          ),
        ),
      );
    });
  });
}
