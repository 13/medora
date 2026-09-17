import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/field_times.dart';
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

  /// A copy with no map: [time] stands for every column (null: unknown).
  FieldTimes rowTimes(DateTime? time) => FieldTimes(const {}, rowTime: time);

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
        localTimes: rowTimes(nine),
        remoteTimes: rowTimes(ten),
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
        localTimes: rowTimes(ten),
        remoteTimes: rowTimes(nine),
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
        localTimes: rowTimes(nine),
        remoteTimes: rowTimes(ten),
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
        localTimes: rowTimes(nine),
        remoteTimes: rowTimes(nine),
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
    });

    test('an automatic change never beats a real one, even a much older '
        'one or one with no known edit time', () {
      const dose = {'id': 'd1', 'status': 'pending', 'taken_time': null};
      for (final remoteAt in [DateTime.utc(2020), null]) {
        final result = mergeRows(
          base: dose,
          local: {...dose, 'status': 'missed'},
          remote: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-01T07:05:00.000Z',
          },
          localTimes: rowTimes(automaticEditedAt),
          remoteTimes: rowTimes(remoteAt),
          policy: doseLogMerge,
        );
        expect(
          [result.row['status'], result.row['taken_time']],
          ['taken', '2026-03-01T07:05:00.000Z'],
          reason: '$remoteAt',
        );
      }
    });

    test('with no base, equal values are no conflict and different ones '
        'go to the later edit', () {
      final result = mergeRows(
        base: null,
        local: {...base, 'name': 'Cold', 'doctor': 'Dr. Bianchi'},
        remote: {...base, 'doctor': 'Dr. Rossi'},
        localTimes: rowTimes(ten),
        remoteTimes: rowTimes(nine),
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
        localTimes: rowTimes(ten),
        remoteTimes: rowTimes(nine),
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
        localTimes: rowTimes(DateTime.utc(2020)),
        remoteTimes: rowTimes(automaticEditedAt),
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
        localTimes: rowTimes(DateTime.utc(2000)),
        remoteTimes: rowTimes(null),
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Local');
    });

    test('an unknown local edit time never beats a known one', () {
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localTimes: rowTimes(null),
        remoteTimes: rowTimes(DateTime.utc(2000)),
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
        localTimes: rowTimes(automaticEditedAt),
        remoteTimes: rowTimes(automaticEditedAt),
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
        localTimes: rowTimes(romeLocal),
        remoteTimes: rowTimes(ten),
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
    });
  });

  group('edit times per column', () {
    // The treatment as C last saw it: before A's and B's changes.
    const cBase = <String, Object?>{
      'id': 't1',
      'notes': 'n0',
      'sick_leave_from': '2026-03-02',
      'sick_leave_to': null,
      'sick_leave_ref': null,
    };
    final nineThirty = DateTime.utc(2026, 3, 5, 9, 30);

    test('A/B/C: an older change to another column does not lower the '
        'time the notes carry', () {
      // A changed notes at 10:00; B's older sick-leave change landed last.
      final remote = {...cBase, 'notes': 'from A', 'sick_leave_ref': 'CERT-B'};
      final remoteTimes = FieldTimes({
        'notes': FieldTime(ten),
        'sick_leave_ref': FieldTime(nine),
        'sick_leave_from': FieldTime(DateTime.utc(2026, 3, 2)),
      }, rowTime: nine);
      final result = mergeRows(
        base: cBase,
        local: {...cBase, 'notes': 'from C'},
        remote: remote,
        localTimes: FieldTimes({'notes': FieldTime(nineThirty)}),
        remoteTimes: remoteTimes,
        policy: treatmentMerge,
      );
      expect(
        [result.row['notes'], result.row['sick_leave_ref']],
        ['from A', 'CERT-B'],
      );
      expect(result.conflicts.single.keptLocal, isFalse);
      expect(result.times.entries, remoteTimes.entries);
    });

    test('a later change here wins its column, and brings its time along', () {
      final result = mergeRows(
        base: cBase,
        local: {...cBase, 'notes': 'from C'},
        remote: {...cBase, 'notes': 'from A', 'sick_leave_ref': 'CERT-B'},
        localTimes: FieldTimes({
          'notes': FieldTime(ten.add(const Duration(minutes: 1))),
          'sick_leave_ref': FieldTime(DateTime.utc(2026, 3)),
        }),
        remoteTimes: FieldTimes({
          'notes': FieldTime(ten),
          'sick_leave_ref': FieldTime(nine),
        }),
        policy: treatmentMerge,
      );
      expect(
        [result.row['notes'], result.row['sick_leave_ref']],
        ['from C', 'CERT-B'],
      );
      expect(result.conflicts.single.keptLocal, isTrue);
      expect(result.times.entries, {
        'notes': FieldTime(ten.add(const Duration(minutes: 1))),
        'sick_leave_ref': FieldTime(nine),
      });
    });

    group('a person\'s change against the app\'s own', () {
      const dose = <String, Object?>{
        'id': 'd1',
        'status': 'pending',
        'taken_time': null,
        'notes': null,
        'scheduled_time': '2026-03-05T07:00:00.000Z',
      };

      test('on the same column: the person wins either way', () {
        final autoHere = mergeRows(
          base: dose,
          local: {...dose, 'status': 'missed', 'notes': 'late'},
          remote: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-05T07:05:00.000Z',
          },
          // The note is a person's (11:00), the missed is the app's own:
          // the note's time must not carry the missed.
          localTimes: FieldTimes({
            'status': FieldTime.automaticChange,
            'notes': FieldTime(DateTime.utc(2026, 3, 5, 11)),
          }, rowTime: DateTime.utc(2026, 3, 5, 11)),
          remoteTimes: FieldTimes({
            'status': FieldTime(DateTime.utc(2026, 3, 5, 7, 5)),
            'taken_time': FieldTime(DateTime.utc(2026, 3, 5, 7, 5)),
          }),
          policy: doseLogMerge,
        );
        expect(
          [
            autoHere.row['status'],
            autoHere.row['taken_time'],
            autoHere.row['notes'],
          ],
          ['taken', '2026-03-05T07:05:00.000Z', 'late'],
        );
        expect(autoHere.conflicts.single.keptLocal, isFalse);

        final autoThere = mergeRows(
          base: dose,
          local: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-05T07:05:00.000Z',
          },
          remote: {...dose, 'status': 'missed', 'notes': 'server note'},
          localTimes: FieldTimes({
            'status': FieldTime(DateTime.utc(2026, 3, 5, 7, 5)),
            'taken_time': FieldTime(DateTime.utc(2026, 3, 5, 7, 5)),
          }),
          remoteTimes: FieldTimes({
            // The server keeps a later time on an automatic entry.
            'status': FieldTime.fromJson({
              'at': '2026-03-05T12:00:00Z',
              'auto': true,
            })!,
            'notes': FieldTime(DateTime.utc(2026, 3, 5, 12)),
          }),
          policy: doseLogMerge,
        );
        expect(
          [autoThere.row['status'], autoThere.row['notes']],
          ['taken', 'server note'],
        );
        expect(autoThere.conflicts.single.keptLocal, isTrue);
      });

      test('on different columns: both are kept, no conflict', () {
        final result = mergeRows(
          base: dose,
          local: {...dose, 'scheduled_time': '2026-03-05T06:00:00.000Z'},
          remote: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-05T06:05:00.000Z',
          },
          localTimes: FieldTimes({'scheduled_time': FieldTime.automaticChange}),
          remoteTimes: FieldTimes({
            'status': FieldTime(DateTime.utc(2026, 3, 5, 6, 5)),
            'taken_time': FieldTime(DateTime.utc(2026, 3, 5, 6, 5)),
          }),
          policy: doseLogMerge,
        );
        expect(
          [
            result.row['scheduled_time'],
            result.row['status'],
            result.row['taken_time'],
          ],
          ['2026-03-05T06:00:00.000Z', 'taken', '2026-03-05T06:05:00.000Z'],
        );
        expect(result.conflicts, isEmpty);
        expect(
          result.times.entries['scheduled_time'],
          FieldTime.automaticChange,
        );
      });

      test('a group goes by the strongest change made to it', () {
        // Here: taken_time corrected by a person at 10:00, status by the
        // app. There: status skipped by a person at 09:00.
        final result = mergeRows(
          base: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-05T07:00:00.000Z',
          },
          local: {
            ...dose,
            'status': 'missed',
            'taken_time': '2026-03-05T07:30:00.000Z',
          },
          remote: {
            ...dose,
            'status': 'skipped',
            'taken_time': '2026-03-05T07:00:00.000Z',
          },
          localTimes: FieldTimes({
            'status': FieldTime.automaticChange,
            'taken_time': FieldTime(ten),
          }),
          remoteTimes: FieldTimes({
            'status': FieldTime(nine),
            'taken_time': FieldTime(DateTime.utc(2026, 3)),
          }),
          policy: doseLogMerge,
        );
        expect(
          [result.row['status'], result.row['taken_time']],
          ['missed', '2026-03-05T07:30:00.000Z'],
        );
      });
    });

    test('a column missing from a filled map is unknown: a person\'s change '
        'beats it, the app\'s own does not', () {
      final remote = {...cBase, 'notes': 'server', 'sick_leave_ref': 'S'};
      final remoteTimes = FieldTimes({
        'sick_leave_from': FieldTime(DateTime.utc(2026, 3, 2)),
      }, rowTime: DateTime.utc(2030));
      final person = mergeRows(
        base: cBase,
        local: {...cBase, 'notes': 'here'},
        remote: remote,
        localTimes: FieldTimes({'notes': FieldTime(DateTime.utc(2000))}),
        remoteTimes: remoteTimes,
        policy: treatmentMerge,
      );
      expect(person.row['notes'], 'here');
      final automatic = mergeRows(
        base: cBase,
        local: {...cBase, 'sick_leave_ref': 'auto'},
        remote: remote,
        localTimes: FieldTimes({'sick_leave_ref': FieldTime.automaticChange}),
        remoteTimes: remoteTimes,
        policy: treatmentMerge,
      );
      expect(automatic.row['sick_leave_ref'], 'S');
    });

    test('with no base, an empty server map stands for the server row\'s '
        'time on every column (a row from before the migration)', () {
      // Another device changed the doctor at 10:00, before the migration;
      // this device changed the notes at 09:00 under 0.3.0 and never
      // pulled the doctor. The server's newer row wins, as under 0.3.0.
      final result = mergeRows(
        base: null,
        local: {...base, 'notes': 'here', 'doctor': null},
        remote: {...base, 'notes': null, 'doctor': 'Dr. Bianchi'},
        localTimes: rowTimes(nine),
        remoteTimes: rowTimes(ten),
        policy: treatmentMerge,
      );
      expect(
        [result.row['notes'], result.row['doctor']],
        [null, 'Dr. Bianchi'],
      );
      expect(result.times.of('doctor'), FieldTime(ten));
      expect(result.times.entries, isNotEmpty);
    });

    test('with no base, a restored row\'s one time meets the server\'s '
        'times column by column', () {
      final result = mergeRows(
        base: null,
        local: {...base, 'notes': 'restored', 'doctor': 'Dr. Rossi'},
        remote: {...base, 'notes': 'older', 'doctor': 'Dr. Bianchi'},
        localTimes: rowTimes(nine),
        remoteTimes: FieldTimes({
          'notes': FieldTime(DateTime.utc(2026, 3, 5, 8)),
          'doctor': FieldTime(ten),
        }),
        policy: treatmentMerge,
      );
      expect(
        [result.row['notes'], result.row['doctor']],
        ['restored', 'Dr. Bianchi'],
      );
      expect(result.times.entries['notes'], FieldTime(nine));
      expect(result.times.entries['doctor'], FieldTime(ten));
    });

    test('column times are compared as instants across the autumn change', () {
      // 02:40 CEST is before 02:10 CET.
      final result = mergeRows(
        base: cBase,
        local: {...cBase, 'notes': 'here'},
        remote: {...cBase, 'notes': 'there'},
        localTimes: FieldTimes({
          'notes': FieldTime(DateTime.parse('2026-10-25T02:10:00+01:00')),
        }),
        remoteTimes: FieldTimes({
          'notes': FieldTime(DateTime.parse('2026-10-25T02:40:00+02:00')),
        }),
        policy: treatmentMerge,
      );
      expect(result.row['notes'], 'here');
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
