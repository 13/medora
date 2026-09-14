import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late PhotoStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('medora_photos_');
    storage = PhotoStorage(rootDirectory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test('saveFromPath copies into the photos folder and returns a bare filename', () async {
    final src = File(p.join(root.path, 'src.jpg'))..writeAsBytesSync([1, 2, 3]);
    final name = await storage.saveFromPath(src.path);
    expect(name, isNot(contains('/')));
    expect(name, endsWith('.jpg'));
    final file = (await storage.resolve(name))!;
    expect(file.existsSync(), isTrue);
    expect(p.dirname(file.path), p.join(root.path, PhotoStorage.folder));
  });

  test('resolve accepts a legacy absolute path that still exists', () async {
    final legacy = File(p.join(root.path, 'legacy.png'))..writeAsBytesSync([9]);
    expect((await storage.resolve(legacy.path))!.path, legacy.path);
  });

  test('resolve maps a stale absolute path to the current folder by basename', () async {
    final name = await storage.saveFromPath(
        (File(p.join(root.path, 'x.jpg'))..writeAsBytesSync([1])).path);
    final stale = '/var/mobile/Containers/OLD/Documents/${PhotoStorage.folder}/$name';
    final file = await storage.resolve(stale);
    expect(file, isNotNull);
    expect(p.basename(file!.path), name);
  });

  test('resolve returns null for null, empty and missing', () async {
    expect(await storage.resolve(null), isNull);
    expect(await storage.resolve(''), isNull);
    expect(await storage.resolve('nope.jpg'), isNull);
  });

  test('delete and deleteAll remove files', () async {
    final a = await storage.saveFromPath((File(p.join(root.path, 'a.jpg'))..writeAsBytesSync([1])).path);
    final b = await storage.saveFromPath((File(p.join(root.path, 'b.jpg'))..writeAsBytesSync([1])).path);
    await storage.delete(a);
    expect(await storage.resolve(a), isNull);
    expect(await storage.resolve(b), isNotNull);
    await storage.deleteAll();
    expect(await storage.resolve(b), isNull);
  });
}
