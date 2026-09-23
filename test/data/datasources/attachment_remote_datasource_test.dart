/// The storage side of attachments against an HTTP stub that answers what
/// Supabase's storage server (storage-api v1.77) really answers; no project
/// is contacted. The error bodies below were recorded from a local stack.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _uid = 'f31858fe-12df-45f7-88a1-c23745f25d49';

/// A storage-api error: it answers HTTP 400 with the real status inside
/// the JSON body.
http.Response storageError(String status, String error, String message) =>
    http.Response(
      jsonEncode({'statusCode': status, 'error': error, 'message': message}),
      400,
      headers: {'content-type': 'application/json'},
    );

final duplicate = storageError(
  '409',
  'Duplicate',
  'The resource already exists',
);
final notFound = storageError('404', 'not_found', 'Object not found');
final rlsDenied = storageError(
  '403',
  'Unauthorized',
  'new row violates row-level security policy',
);
final badJwt = storageError('400', 'InvalidJWT', 'jwt expired');
final noBucket = storageError('404', 'Bucket not found', 'Bucket not found');

class Stub {
  Stub(this.answer);

  http.Response Function(http.Request request) answer;
  final requests = <http.Request>[];

  late final SupabaseClient client = () {
    final c = SupabaseClient(
      'http://supabase.invalid',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final a = answer(request);
        return http.Response.bytes(
          a.bodyBytes,
          a.statusCode,
          headers: a.headers,
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(c.dispose);
    return c;
  }();

  late final store = SupabaseAttachmentStore(client);
}

void main() {
  final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);

  group('upload', () {
    test('sends the bytes to the private bucket without overwriting', () async {
      final stub = Stub(
        (_) => http.Response(
          jsonEncode({'Key': 'attachments/$_uid/a1.jpg', 'Id': 'x'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await stub.store.upload('$_uid/a1.jpg', bytes, mime: 'image/jpeg');
      final request = stub.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/storage/v1/object/${SupabaseAttachmentStore.bucket}/$_uid/a1.jpg',
      );
      expect(request.headers['x-upsert'], 'false');
    });

    test('an object already there counts as done', () async {
      final stub = Stub((_) => duplicate);
      await stub.store.upload('$_uid/a1.jpg', bytes, mime: 'image/jpeg');
      expect(stub.requests, hasLength(1));
    });

    test('a newer server answering 409 itself counts as done too', () async {
      final stub = Stub(
        (_) => http.Response(
          jsonEncode({'error': 'Duplicate', 'message': 'exists'}),
          409,
          headers: {'content-type': 'application/json'},
        ),
      );
      await stub.store.upload('$_uid/a1.jpg', bytes, mime: 'image/jpeg');
    });

    test('a refused folder is an error', () async {
      final stub = Stub((_) => rlsDenied);
      await expectLater(
        stub.store.upload('other/a1.jpg', bytes, mime: 'image/jpeg'),
        throwsA(
          isA<StorageException>().having((e) => e.statusCode, 'status', '403'),
        ),
      );
    });
  });

  group('download', () {
    test('returns the bytes', () async {
      final stub = Stub((_) => http.Response.bytes(bytes, 200));
      expect(await stub.store.download('$_uid/a1.jpg'), bytes);
      expect(
        stub.requests.single.url.path,
        '/storage/v1/object/attachments/$_uid/a1.jpg',
      );
    });

    test('a missing object is AttachmentNotFound', () async {
      final stub = Stub((_) => notFound);
      await expectLater(
        stub.store.download('$_uid/a1.jpg'),
        throwsA(
          isA<AttachmentNotFound>().having(
            (e) => e.path,
            'path',
            '$_uid/a1.jpg',
          ),
        ),
      );
    });

    test('a bare 404 is AttachmentNotFound', () async {
      final stub = Stub((_) => http.Response('', 404));
      await expectLater(
        stub.store.download('$_uid/a1.jpg'),
        throwsA(isA<AttachmentNotFound>()),
      );
    });

    test('other refusals, also answered 400, are not', () async {
      for (final answer in [badJwt, noBucket, http.Response('oops', 500)]) {
        final stub = Stub((_) => answer);
        await expectLater(
          stub.store.download('$_uid/a1.jpg'),
          throwsA(isA<StorageException>()),
        );
      }
    });
  });

  test(
    'remove sends every path at once; nothing to remove sends nothing',
    () async {
      final stub = Stub(
        (_) => http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await stub.store.remove(const []);
      expect(stub.requests, isEmpty);
      await stub.store.remove(['$_uid/a.jpg', '$_uid/b.pdf']);
      final request = stub.requests.single;
      expect(request.method, 'DELETE');
      expect(jsonDecode(request.body), {
        'prefixes': ['$_uid/a.jpg', '$_uid/b.pdf'],
      });
    },
  );

  test('listFolder reads every page and skips sub-folders', () async {
    final names = [for (var i = 0; i < 150; i++) 'a$i.jpg'];
    final stub = Stub((request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final offset = body['offset'] as int;
      final limit = body['limit'] as int;
      expect(body['prefix'], _uid);
      final entries = [
        {'name': 'sub', 'id': null, 'metadata': null},
        for (final n in names)
          {'name': n, 'id': 'id-$n', 'metadata': <String, Object?>{}},
      ];
      final page = entries.skip(offset).take(limit).toList();
      return http.Response(
        jsonEncode(page),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final listed = await stub.store.listFolder(_uid);
    expect(listed, [for (final n in names) '$_uid/$n']);
  });
}
