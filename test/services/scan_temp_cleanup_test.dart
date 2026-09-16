import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/scan_temp_cleanup.dart';

void main() {
  late Directory temp;

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

    expect(await cleanScanTempDirs(temp), 3);

    final left = temp.listSync().map((e) => e.path.split('/').last).toSet();
    expect(left, {'image_picker_xyz', 'scan_region_file.png'});
  });

  test('deletes a folder with contents', () async {
    final dir = await Directory('${temp.path}/scan_region_abc').create();
    await File('${dir.path}/region.png').writeAsString('x');
    expect(await cleanScanTempDirs(temp), 1);
    expect(dir.existsSync(), isFalse);
  });

  test('a missing temp directory is not an error', () async {
    final gone = Directory('${temp.path}/nope');
    expect(await cleanScanTempDirs(gone), 0);
  });
}
