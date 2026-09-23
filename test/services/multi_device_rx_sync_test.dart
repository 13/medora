import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/rx/rx_rules.dart';

import '../helpers/test_database.dart';
import '../helpers/two_devices.dart';

void main() {
  for (final transport in FakeTransport.values) {
    group('over ${transport.name}', () => _scenarios(transport));
  }
}

void _scenarios(FakeTransport transport) {
  late TwoDevices h;

  setUp(() async {
    await setUpTestDatabase();
    h = TwoDevices(transport: transport);
    // A records a repeatable prescription; B has synced it since.
    await h.a.run(
      (_) => h.a.rx.saveRx(
        Rx(
          id: 'r1',
          kind: RxKind.whiteRepeatable,
          issuedOn: DateTime(2026, 3),
          maxDispensings: 3,
          items: const [RxItem(id: 'i1', description: 'Brufen')],
        ),
      ),
    );
    h.advance(const Duration(minutes: 5));
    await h.b.sync();
  });
  tearDown(() => h.dispose());

  RxDispensing collect(String id, DateTime day) => RxDispensing(
    id: id,
    rxId: 'r1',
    itemId: 'i1',
    packs: 1,
    dispensedOn: day,
  );

  test('concurrent dispensings from two devices both survive', () async {
    // Both collect offline, on different days, then come back online.
    h.a.online = false;
    h.b.online = false;
    h.advance(const Duration(hours: 1));
    await h.a.run(
      (_) => h.a.rx.redeem('r1', [collect('da', DateTime(2026, 3, 5))]),
    );
    h.advance(const Duration(minutes: 1));
    await h.b.run(
      (_) => h.b.rx.redeem('r1', [collect('db', DateTime(2026, 3, 6))]),
    );
    h.a.online = true;
    h.b.online = true;

    h.advance(const Duration(minutes: 1));
    await h.a.sync();
    h.advance(const Duration(minutes: 1));
    await h.b.sync();
    h.advance(const Duration(minutes: 1));
    await h.a.sync();

    Future<Set<String>> collections(Device d) => d.run(
      (_) async => {
        for (final x in (await d.rx.getById('r1')).dataOrNull!.dispensings)
          x.id,
      },
    );
    expect(await collections(h.a), {'da', 'db'});
    expect(await collections(h.b), {'da', 'db'});
    expect(
      h.server.rx.dispensings.rows.values
          .where((r) => r['deleted_at'] == null)
          .map((r) => r['id'])
          .toSet(),
      {'da', 'db'},
    );
  });
}
