import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/attachment_files.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late AttachmentFiles files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('att');
    files = AttachmentFiles(rootDirectory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  const photo = Attachment(
    id: 'a1',
    ownerKind: AttachmentOwnerKind.rx,
    ownerId: 'r1',
    kind: AttachmentKind.photo,
    mime: 'image/jpeg',
    sizeBytes: 3,
    sha256: 'x',
  );

  test('bytes are stored under attachments/<id>.<ext>', () async {
    await files.write(photo.fileName, [1, 2, 3]);
    expect(await files.has(photo), isTrue);
    final f = await files.fileFor(photo);
    expect(f.path, endsWith('attachments/a1.jpg'));
    expect(await f.readAsBytes(), [1, 2, 3]);
    expect(await files.listNames(), ['a1.jpg']);
  });

  test('a name with a directory part is reduced to its basename', () async {
    await files.write('../../evil.jpg', [1]);
    expect(await files.listNames(), ['evil.jpg']);
  });

  test(
    'fileFor() with path traversal id does not leave attachments folder',
    () async {
      const evilAttachment = Attachment(
        id: '../../escape',
        ownerKind: AttachmentOwnerKind.rx,
        ownerId: 'r1',
        kind: AttachmentKind.photo,
        mime: 'image/jpeg',
        sizeBytes: 0,
        sha256: 'x',
      );
      final file = await files.fileFor(evilAttachment);
      final fileDir = p.dirname(file.path);
      final attachmentsDir = p.join(root.path, 'attachments');
      expect(
        fileDir,
        equals(attachmentsDir),
        reason:
            'fileFor() path parent should be attachments folder, got $fileDir, expected $attachmentsDir',
      );
    },
  );

  test('delete and deleteAll remove files', () async {
    await files.write('a1.jpg', [1]);
    await files.write('a2.pdf', [2]);
    await files.delete('a1.jpg');
    expect(await files.listNames(), ['a2.pdf']);
    await files.deleteAll();
    expect(await files.listNames(), isEmpty);
  });
}
