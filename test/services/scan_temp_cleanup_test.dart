import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/scan_temp_cleanup.dart';

void main() {
  late Directory temp;

  /// The fixtures are created right now, so "later" is what makes them old
  /// enough for the sweep's age guard.
  DateTime later() => DateTime.now().add(const Duration(hours: 1));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cleanup_test_');
  });
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('deletes only scanner crop folders', () async {
    await Directory('${temp.path}/scan_region_abc').create();
    await Directory('${temp.path}/scan_stripe_def').create();
    await Directory('${temp.path}/scan_area_ghi').create();
    await Directory('${temp.path}/image_picker_xyz').create();
    await File('${temp.path}/scan_region_file.png').writeAsString('x');

    expect(await cleanScanTempDirs(temp, now: later), 3);

    final left = temp.listSync().map((e) => e.path.split('/').last).toSet();
    expect(left, {'image_picker_xyz', 'scan_region_file.png'});
  });

  test('deletes a folder with contents', () async {
    final dir = await Directory('${temp.path}/scan_region_abc').create();
    await File('${dir.path}/region.png').writeAsString('x');
    expect(await cleanScanTempDirs(temp, now: later), 1);
    expect(dir.existsSync(), isFalse);
  });

  test('a missing temp directory is not an error', () async {
    final gone = Directory('${temp.path}/nope');
    expect(await cleanScanTempDirs(gone, now: later), 0);
  });

  test('a folder younger than minAge is left alone', () async {
    // The live case: a scan started while the app was in the background and
    // is writing its crop right now. Sweeping it breaks that scan.
    final live = await Directory('${temp.path}/scan_area_live').create();
    await File('${live.path}/area.png').writeAsString('x');

    expect(await cleanScanTempDirs(temp), 0);
    expect(live.existsSync(), isTrue);
  });

  test('a folder older than minAge is swept', () async {
    final old = await Directory('${temp.path}/scan_area_old').create();

    expect(
      await cleanScanTempDirs(
        temp,
        // Just past the default scanTempMinAge.
        now: () => DateTime.now().add(const Duration(minutes: 11)),
      ),
      1,
    );
    expect(old.existsSync(), isFalse);
  });
}
