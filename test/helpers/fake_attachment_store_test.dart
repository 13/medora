import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;

import 'fake_remotes.dart';

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  test(
    'keeps objects in the user\'s folder, as the storage policies do',
    () async {
      final store = FakeAttachmentStore(currentUserId: 'u1');
      await store.upload('u1/a.jpg', bytes, mime: 'image/jpeg');
      // A retried upload counts as done.
      await store.upload('u1/a.jpg', bytes, mime: 'image/jpeg');
      expect(await store.download('u1/a.jpg'), bytes);
      expect(await store.listFolder('u1'), ['u1/a.jpg']);
      await expectLater(
        store.upload('u2/a.jpg', bytes, mime: 'image/jpeg'),
        throwsA(isA<StorageException>()),
      );
      await expectLater(
        store.upload('a.jpg', bytes, mime: 'image/jpeg'),
        throwsA(isA<StorageException>()),
      );
      await store.remove(['u1/a.jpg', 'u1/missing.jpg']);
      await expectLater(
        store.download('u1/a.jpg'),
        throwsA(isA<AttachmentNotFound>()),
      );
      expect(store.uploads, 4);
    },
  );

  test('another user\'s objects are invisible and stay', () async {
    final store = FakeAttachmentStore(currentUserId: 'u1');
    store.objects['u2/b.pdf'] = bytes;
    await expectLater(
      store.download('u2/b.pdf'),
      throwsA(isA<AttachmentNotFound>()),
    );
    expect(await store.listFolder('u2'), isEmpty);
    await store.remove(['u2/b.pdf']);
    expect(store.objects, contains('u2/b.pdf'));
  });

  test('fails the next N calls', () async {
    final store = FakeAttachmentStore(currentUserId: 'u1')..failNext = 2;
    for (var i = 0; i < 2; i++) {
      await expectLater(
        store.listFolder('u1'),
        throwsA(isA<StorageException>()),
      );
    }
    expect(await store.listFolder('u1'), isEmpty);
  });
}
