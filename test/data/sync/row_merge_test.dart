import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/sync/row_merge.dart';

void main() {
  // The illness as both devices last saw it on the server.
  const base = <String, Object?>{
    'id': 't1',
    'name': 'Sinusitis',
    'end_date': null,
    'is_active': true,
    'sick_leave_from': '2026-03-02',
    'sick_leave_to': null,
    'sick_leave_ref': null,
    'updated_at': '2026-03-02T09:00:00.000Z',
  };
  // A table whose `quantity` only the server writes.
  const stockOwned = MergePolicy(groups: [], serverOwned: {'quantity'});
  final nine = DateTime.utc(2026, 3, 5, 9);
  final ten = DateTime.utc(2026, 3, 5, 10);

  group('changedColumns', () {
    test('lists what differs from the base, bookkeeping left out', () {
      final local = {
        ...base,
        'sick_leave_ref': 'CERT-B',
        'updated_at': '2026-03-05T10:00:00.000Z',
      };
      expect(changedColumns(base, local, treatmentMerge), {'sick_leave_ref'});
    });

    test('with no base every column counts, bookkeeping still left out', () {
      expect(changedColumns(null, base, treatmentMerge), {
        'name',
        'end_date',
        'is_active',
        'sick_leave_from',
        'sick_leave_to',
        'sick_leave_ref',
      });
    });

    test('never lists a server-owned column', () {
      const med = {'id': 'm1', 'name': 'Ibu', 'quantity': 10};
      expect(changedColumns(med, {...med, 'quantity': 8}, stockOwned), isEmpty);
    });
  });

  group('mergeRows', () {
    test('S1: different groups changed on each side are both kept', () {
      // A ended the illness (on the server); B added the certificate.
      final remote = {
        ...base,
        'end_date': '2026-03-05',
        'is_active': false,
        'sick_leave_to': '2026-03-05',
      };
      final local = {...base, 'sick_leave_ref': 'CERT-B'};
      final result = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: nine,
        remoteEditedAt: ten,
        policy: treatmentMerge,
      );
      expect(
        [
          result.row['end_date'],
          result.row['is_active'],
          result.row['sick_leave_to'],
          result.row['sick_leave_ref'],
        ],
        ['2026-03-05', false, '2026-03-05', 'CERT-B'],
      );
      expect(result.conflicts, isEmpty);
    });

    test('the same group changed on both sides: the later edit wins, '
        'as a whole group', () {
      final remote = {
        ...base,
        'sick_leave_from': '2026-03-03',
        'sick_leave_to': '2026-03-06',
      };
      final local = {...base, 'sick_leave_to': '2026-03-09'};
      final localLater = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(
        [localLater.row['sick_leave_from'], localLater.row['sick_leave_to']],
        ['2026-03-02', '2026-03-09'],
      );
      expect(localLater.conflicts.single.keptLocal, isTrue);
      expect(localLater.conflicts.single.columns, {
        'sick_leave_from',
        'sick_leave_to',
      });

      final remoteLater = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: nine,
        remoteEditedAt: ten,
        policy: treatmentMerge,
      );
      expect(
        [remoteLater.row['sick_leave_from'], remoteLater.row['sick_leave_to']],
        ['2026-03-03', '2026-03-06'],
      );
      expect(remoteLater.conflicts.single.keptLocal, isFalse);
    });

    test('a tie keeps the server copy', () {
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localEditedAt: nine,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
    });

    test('an automatic change never beats a real one, even a much older '
        'one or one with no known edit time', () {
      const dose = {'id': 'd1', 'status': 'pending', 'taken_time': null};
      for (final remoteEditedAt in [DateTime.utc(2020), null]) {
        final result = mergeRows(
          base: dose,
          local: {...dose, 'status': 'missed'},
          remote: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-01T07:05:00.000Z',
          },
          localEditedAt: automaticEditedAt,
          remoteEditedAt: remoteEditedAt,
          policy: doseLogMerge,
        );
        expect(
          [result.row['status'], result.row['taken_time']],
          ['taken', '2026-03-01T07:05:00.000Z'],
          reason: '$remoteEditedAt',
        );
      }
    });

    test('with no base, equal values are no conflict and different ones '
        'go to the later edit', () {
      final result = mergeRows(
        base: null,
        local: {...base, 'name': 'Cold', 'doctor': 'Dr. Bianchi'},
        remote: {...base, 'doctor': 'Dr. Rossi'},
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(
        [result.row['name'], result.row['doctor'], result.row['is_active']],
        ['Cold', 'Dr. Bianchi', true],
      );
      expect(result.conflicts.map((c) => c.columns), [
        {'name'},
        {'doctor'},
      ]);
    });

    test('a server-owned column always comes from the server', () {
      const med = {'id': 'm1', 'name': 'Ibu', 'quantity': 10};
      final result = mergeRows(
        base: med,
        local: {...med, 'name': 'Ibuprofen', 'quantity': 3},
        remote: {...med, 'quantity': 8},
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: stockOwned,
      );
      expect([result.row['name'], result.row['quantity']], ['Ibuprofen', 8]);
    });

    test('a real change beats an automatic one on the server, even a much '
        'older real change', () {
      const dose = {'id': 'd1', 'status': 'pending', 'taken_time': null};
      final result = mergeRows(
        base: dose,
        local: {
          ...dose,
          'status': 'taken',
          'taken_time': '2020-01-01T07:05:00.000Z',
        },
        remote: {...dose, 'status': 'missed'},
        localEditedAt: DateTime.utc(2020),
        remoteEditedAt: automaticEditedAt,
        policy: doseLogMerge,
      );
      expect(
        [result.row['status'], result.row['taken_time']],
        ['taken', '2020-01-01T07:05:00.000Z'],
      );
      expect(result.conflicts.single.keptLocal, isTrue);
    });

    test('a real edit beats a server copy with no known edit time', () {
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localEditedAt: DateTime.utc(2000),
        remoteEditedAt: null,
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Local');
    });

    test('an unknown local edit time never beats a known one', () {
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localEditedAt: null,
        remoteEditedAt: DateTime.utc(2000),
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
      expect(result.conflicts.single.keptLocal, isFalse);
    });

    test('two automatic changes: the server copy is kept', () {
      const dose = {'id': 'd1', 'status': 'pending', 'taken_time': null};
      final result = mergeRows(
        base: dose,
        local: {...dose, 'status': 'missed'},
        remote: {...dose, 'status': 'skipped'},
        localEditedAt: automaticEditedAt,
        remoteEditedAt: automaticEditedAt,
        policy: doseLogMerge,
      );
      expect(result.row['status'], 'skipped');
    });

    test('edit times are compared as instants, whatever their zone', () {
      // 10:30 in Rome (CET, UTC+1) is 09:30 UTC: earlier than 10:00 UTC,
      // although its wall-clock reading is later.
      final romeLocal = DateTime.parse('2026-03-05T10:30:00.000+01:00');
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localEditedAt: romeLocal,
        remoteEditedAt: ten,
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
    });
  });

  test('mergePolicyOf knows the four synced tables only', () {
    expect(mergePolicyOf('dose_logs'), same(doseLogMerge));
    expect(() => mergePolicyOf('families'), throwsArgumentError);
  });

  test('sameContent ignores bookkeeping', () {
    expect(
      sameContent(base, {...base, 'updated_at': 'later'}, treatmentMerge),
      isTrue,
    );
    expect(sameContent(base, {...base, 'name': 'x'}, treatmentMerge), isFalse);
  });
}
