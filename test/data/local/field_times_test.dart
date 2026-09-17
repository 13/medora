import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/field_times.dart';

void main() {
  final nine = DateTime.utc(2026, 3, 5, 9);
  final ten = DateTime.utc(2026, 3, 5, 10);

  group('FieldTime', () {
    test('a time before 1970-01-02 is an automatic change', () {
      expect(FieldTime(DateTime.utc(1970, 1, 1, 23)).automatic, isTrue);
      expect(FieldTime(DateTime.utc(1970, 1, 1, 23)).at, DateTime.utc(1970));
      expect(FieldTime(DateTime.utc(1970, 1, 2)).automatic, isFalse);
      expect(FieldTime.automaticChange.at, DateTime.utc(1970));
    });

    test('is kept in UTC, whatever zone the time was read in', () {
      final rome = DateTime.parse('2026-10-25T02:30:00.000+02:00');
      expect(FieldTime(rome).at.isUtc, isTrue);
      expect(FieldTime(rome).toJson(), {
        'at': '2026-10-25T00:30:00.000Z',
        'auto': false,
      });
      expect(
        FieldTime(nine.toLocal()).toJson()['at'],
        '2026-03-05T09:00:00.000Z',
      );
    });

    test('reads what the server writes, flag included', () {
      expect(
        FieldTime.fromJson({'at': '2026-03-05T09:00:00+00:00', 'auto': false}),
        FieldTime(nine),
      );
      final auto = FieldTime.fromJson({
        'at': '2026-03-05T09:00:00+00:00',
        'auto': true,
      })!;
      expect([auto.automatic, auto.at], [true, nine]);
      expect(
        FieldTime.fromJson({'at': '1970-01-01T00:00:00+00:00'}),
        FieldTime.automaticChange,
      );
      expect(FieldTime.fromJson({'at': 'garbage'}), isNull);
      expect(FieldTime.fromJson('2026-03-05T09:00:00Z'), isNull);
      expect(FieldTime.fromJson(null), isNull);
    });

    test('beats: a person\'s change beats an unknown time, which beats an '
        'automatic change; a tie keeps the other side', () {
      final auto = FieldTime.automaticChange;
      final serverAuto = FieldTime.fromJson({
        'at': ten.toIso8601String(),
        'auto': true,
      });
      expect(beats(FieldTime(ten), FieldTime(nine)), isTrue);
      expect(beats(FieldTime(nine), FieldTime(ten)), isFalse);
      expect(beats(FieldTime(nine), FieldTime(nine)), isFalse);
      expect(beats(FieldTime(DateTime.utc(2000)), null), isTrue);
      expect(beats(FieldTime(DateTime.utc(2000)), auto), isTrue);
      expect(beats(FieldTime(nine), serverAuto), isTrue);
      expect(beats(null, auto), isTrue);
      expect(beats(null, null), isFalse);
      expect(beats(null, FieldTime(DateTime.utc(2000))), isFalse);
      expect(beats(auto, null), isFalse);
      expect(beats(auto, auto), isFalse);
      expect(beats(serverAuto, FieldTime(nine)), isFalse);
    });

    test('beats compares instants, not wall-clock readings', () {
      // 02:40 CEST is earlier than 02:10 CET on the autumn night.
      final summer = DateTime.parse('2026-10-25T02:40:00+02:00');
      final winter = DateTime.parse('2026-10-25T02:10:00+01:00');
      expect(beats(FieldTime(winter), FieldTime(summer)), isTrue);
      expect(beats(FieldTime(summer), FieldTime(winter)), isFalse);
    });
  });

  group('FieldTimes', () {
    test('an empty map stands for the row time on every column', () {
      final times = FieldTimes.decode(null, rowTime: nine);
      expect(times.of('notes'), FieldTime(nine));
      expect(
        FieldTimes.decode('{}', rowTime: DateTime.utc(1970)).of('status'),
        FieldTime.automaticChange,
      );
      expect(FieldTimes.decode(null).of('notes'), isNull);
    });

    test('an entry wins over the row time; a column missing from a filled '
        'map is unknown', () {
      final times = FieldTimes.decode(
        jsonEncode({
          'notes': {'at': '2026-03-05T10:00:00.000Z', 'auto': false},
        }),
        rowTime: nine,
      );
      expect(times.of('notes'), FieldTime(ten));
      expect(times.of('doctor'), isNull);
    });

    test('reads the server\'s map and the local JSON text alike; a broken '
        'value is no map', () {
      final server = FieldTimes.decode({
        'status': {'at': '1970-01-01T00:00:00+00:00', 'auto': true},
      });
      expect(server.of('status'), FieldTime.automaticChange);
      expect(
        FieldTimes.decode('not json', rowTime: nine).of('x'),
        FieldTime(nine),
      );
      expect(FieldTimes.decode('[1]', rowTime: nine).of('x'), FieldTime(nine));
      expect(
        FieldTimes.decode({'notes': 'garbage'}, rowTime: nine).of('notes'),
        FieldTime(nine),
        reason: 'an entry that does not parse is left out',
      );
    });

    test('strongestOf picks the change that beats the others', () {
      final times = FieldTimes({
        'status': FieldTime.automaticChange,
        'taken_time': FieldTime(nine),
        'notes': FieldTime(ten),
      });
      expect(times.strongestOf(['status']), FieldTime.automaticChange);
      expect(times.strongestOf(['status', 'taken_time']), FieldTime(nine));
      expect(times.strongestOf(['status', 'unknown']), isNull);
      expect(
        times.strongestOf(['taken_time', 'unknown', 'notes']),
        FieldTime(ten),
      );
      expect(times.strongestOf([]), isNull);
    });

    test('stamped fills an empty map from the row time, then stamps the '
        'changed columns only', () {
      final stamped = FieldTimes.decode(null, rowTime: nine).stamped(
        columns: ['id', 'name', 'notes', 'doctor', 'updated_at', 'quantity'],
        changed: ['notes'],
        at: ten,
      );
      expect(stamped.entries, {
        'name': FieldTime(nine),
        'notes': FieldTime(ten),
        'doctor': FieldTime(nine),
      });
    });

    test('stamped keeps the other entries of a filled map, and never stamps '
        'bookkeeping or the stock', () {
      final stamped =
          FieldTimes({
            'name': FieldTime(nine),
            'notes': FieldTime(nine),
          }).stamped(
            columns: ['name', 'notes', 'quantity'],
            changed: ['notes', 'quantity', 'updated_at', 'deleted_at'],
            at: DateTime.utc(1970),
          );
      expect(stamped.entries, {
        'name': FieldTime(nine),
        'notes': FieldTime.automaticChange,
      });
    });

    test('encode writes UTC JSON, and nothing for an empty map', () {
      expect(FieldTimes(const {}).encode(), isNull);
      expect(
        jsonDecode(FieldTimes({'notes': FieldTime(nine.toLocal())}).encode()!),
        {
          'notes': {'at': '2026-03-05T09:00:00.000Z', 'auto': false},
        },
      );
    });
  });

  group('timedChanges', () {
    const before = {
      'id': 'd1',
      'status': 'pending',
      'taken_time': null,
      'notes': null,
      'quantity': 3,
      'updated_at': '2026-03-05T09:00:00.000Z',
    };

    test('lists the data columns whose value changed', () {
      expect(
        timedChanges(before, {
          ...before,
          'status': 'taken',
          'quantity': 2,
          'updated_at': '2026-03-05T10:00:00.000Z',
        }),
        {'status'},
      );
    });

    test('with nothing before, every data column counts', () {
      expect(timedChanges(null, before), {'status', 'taken_time', 'notes'});
    });
  });

  group('fieldTimesAfterWrite', () {
    Map<String, Object?> wire(Map<String, Object?> row) => {
      'id': row['id'],
      'status': row['status'],
      'notes': row['notes'],
      'updated_at': row['updated_at'],
    };

    test('a new row stores no map: its edit time stands for every column', () {
      expect(
        fieldTimesAfterWrite(
          previous: null,
          after: {'id': 'd1', 'status': 'pending'},
          wireOf: wire,
          at: ten,
        ),
        isNull,
      );
    });

    test('a change fills the map from the row\'s previous time and stamps '
        'what it changed', () {
      final previous = {
        'id': 'd1',
        'status': 'pending',
        'notes': null,
        'updated_at': '2026-03-05T09:00:00.000',
        'edited_at': '2026-03-05T09:00:00.000Z',
        'field_edited_at': null,
      };
      final text = fieldTimesAfterWrite(
        previous: previous,
        after: {...previous, 'status': 'taken'},
        wireOf: wire,
        at: ten,
      );
      expect(FieldTimes.decode(text).entries, {
        'status': FieldTime(ten),
        'notes': FieldTime(nine),
      });
    });

    test('with no edit time the row\'s updated_at is its time', () {
      final wallClock = nine.toLocal().toIso8601String();
      final previous = {
        'id': 'd1',
        'status': 'pending',
        'notes': null,
        'updated_at': wallClock,
        'edited_at': null,
      };
      final text = fieldTimesAfterWrite(
        previous: previous,
        after: {...previous, 'notes': 'x'},
        wireOf: wire,
        at: ten,
      );
      expect(FieldTimes.decode(text).of('status'), FieldTime(nine));
      expect(localRowTime(previous), nine);
    });
  });
}
