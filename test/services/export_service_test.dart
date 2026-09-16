import 'package:csv/csv.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/intake_count.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/services/export_service.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await initializeDateFormatting('it');
    await initializeDateFormatting('en');
  });
  test(
    'dose status labels are localized in Italian and not the raw enum name',
    () {
      final l10n = lookupAppLocalizations(const Locale('it'));
      final labels = ExportLabels.fromL10n(l10n);

      expect(labels.statusLabel(DoseStatus.taken), l10n.taken);
      expect(labels.statusLabel(DoseStatus.skipped), l10n.skipped);
      expect(labels.statusLabel(DoseStatus.missed), l10n.missed);
      expect(labels.statusLabel(DoseStatus.pending), l10n.pending);
      expect(labels.statusLabel(DoseStatus.taken), isNot('taken'));
    },
  );

  test('CSV rows use the localized status, not DoseStatus.name', () {
    final l10n = lookupAppLocalizations(const Locale('it'));
    final labels = ExportLabels.fromL10n(l10n);
    final dose = DoseLog(
      id: 'd1',
      prescriptionId: 'p1',
      scheduledTime: DateTime(2026, 3, 4, 8),
      status: DoseStatus.taken,
    );

    final row = doseLogCsvRow(dose, labels);
    expect(row, contains(l10n.taken));
    expect(row, isNot(contains('taken')));
  });

  test('PDF rows use the localized status, not DoseStatus.name', () {
    final l10n = lookupAppLocalizations(const Locale('it'));
    final labels = ExportLabels.fromL10n(l10n);
    final dose = DoseLog(
      id: 'd1',
      prescriptionId: 'p1',
      scheduledTime: DateTime(2026, 3, 4, 8),
      status: DoseStatus.skipped,
    );

    final row = doseLogPdfRow(dose, labels);
    expect(row, contains(l10n.skipped));
    expect(row, isNot(contains('skipped')));
  });

  group('the episode summary', () {
    EpisodeLabels labelsFor(String locale) =>
        EpisodeLabels.fromL10n(lookupAppLocalizations(Locale(locale)));

    final sinusitis = Treatment(
      id: 't1',
      name: 'Stirnhöhlenentzündung',
      patientTags: const ['Lena'],
      symptomTags: const ['Kopfschmerzen', 'Fieber'],
      startDate: DateTime(2026, 3, 2),
      endDate: DateTime(2026, 3, 11),
      isActive: false,
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveTo: DateTime(2026, 3, 9),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
      notes: 'ging langsam weg',
    );
    final ibuprofen = Prescription(
      id: 'p1',
      treatmentId: 't1',
      medicationId: 'm1',
      dosage: '1 tablets',
      dosageAmount: 1,
      durationDays: 5,
      startTime: DateTime(2026, 3, 3, 8),
      scheduleType: 'times_per_day',
      scheduleTimes: const ['08:00', '14:00', '20:00'],
      medicationName: 'Ibuprofen 400',
    );
    final tachipirina = Prescription(
      id: 'p2',
      treatmentId: 't1',
      medicationId: 'm2',
      dosage: '1 tablets',
      dosageAmount: 1,
      durationDays: 0,
      startTime: DateTime(2026, 3, 3, 8),
      scheduleType: 'as_needed',
      medicationName: 'Tachipirina 1000',
    );
    // 15 scheduled doses, the 8th one missed; three logged as needed.
    final sinusitisDoses = [
      for (var i = 0; i < 15; i++)
        DoseLog(
          id: 's$i',
          prescriptionId: 'p1',
          scheduledTime: ibuprofen.scheduledDoseTimes[i],
          status: i == 7 ? DoseStatus.missed : DoseStatus.taken,
        ),
      for (var i = 0; i < 3; i++)
        DoseLog(
          id: 'a$i',
          prescriptionId: 'p2',
          scheduledTime: DateTime(2026, 3, 4 + i, 15),
          takenTime: DateTime(2026, 3, 4 + i, 15),
          status: DoseStatus.taken,
          asNeeded: true,
        ),
    ];

    String summary(
      String locale, {
      Treatment? treatment,
      List<Prescription>? prescriptions,
      List<DoseLog>? doses,
      DateTime? now,
      Duration grace = Duration.zero,
    }) {
      final l10n = lookupAppLocalizations(Locale(locale));
      return buildEpisodeSummary(
        treatment: treatment ?? sinusitis,
        prescriptions: prescriptions ?? [ibuprofen, tachipirina],
        doses: doses ?? sinusitisDoses,
        labels: EpisodeLabels.fromL10n(l10n),
        now: now ?? DateTime(2026, 3, 12),
        grace: grace,
        // The real formatter, with the unit the medication is counted in:
        // the sheet stores "1 tablets", the raw key.
        dosageText: (p) =>
            prescriptionDosageLabel(l10n, p, medicationUnit: 'tablets'),
      );
    }

    test('reads naturally in German, with every part of the episode', () {
      expect(
        summary('de'),
        'Stirnhöhlenentzündung\n'
        'Patient/in: Lena\n'
        'Krankheit: 2. März 2026 – 11. März 2026\n'
        'Krankenstand: 3. März 2026 – 9. März 2026 (7 Tage)\n'
        'Protokollnummer: 1234567890\n'
        'Ärztin/Arzt: Dr. Rossi, Bozen\n'
        'Symptome: Kopfschmerzen, Fieber\n'
        'Medikamente:\n'
        '- Ibuprofen 400: 1 Tablette · 3 mal täglich · 5 Tage\n'
        '  14 von 15 eingenommen\n'
        '- Tachipirina 1000: 1 Tablette · Bei Bedarf\n'
        '  3 eingenommen (4. März 2026 – 6. März 2026)\n'
        'Notizen: ging langsam weg',
      );
    });

    test('reads naturally in Italian, where the illness and the sick leave '
        'are told apart', () {
      expect(
        summary('it'),
        'Stirnhöhlenentzündung\n'
        'Paziente: Lena\n'
        'Malattia: 2 mar 2026 – 11 mar 2026\n'
        'Assenza per malattia: 3 mar 2026 – 9 mar 2026 (7 giorni)\n'
        'Numero di protocollo: 1234567890\n'
        'Medico: Dr. Rossi, Bozen\n'
        'Sintomi: Kopfschmerzen, Fieber\n'
        'Farmaci:\n'
        '- Ibuprofen 400: 1 compressa · 3 volte al giorno · 5 giorni\n'
        '  14 su 15 assunte\n'
        '- Tachipirina 1000: 1 compressa · Al bisogno\n'
        '  3 dosi assunte (4 mar 2026 – 6 mar 2026)\n'
        'Note: ging langsam weg',
      );
    });

    test('reads naturally in English', () {
      expect(
        summary('en'),
        'Stirnhöhlenentzündung\n'
        'Patient: Lena\n'
        'Illness: Mar 2, 2026 – Mar 11, 2026\n'
        'Sick leave: Mar 3, 2026 – Mar 9, 2026 (7 days)\n'
        'Certificate no.: 1234567890\n'
        'Doctor: Dr. Rossi, Bozen\n'
        'Symptoms: Kopfschmerzen, Fieber\n'
        'Medications:\n'
        '- Ibuprofen 400: 1 tablet · 3 times daily · 5 days\n'
        '  14 of 15 taken\n'
        '- Tachipirina 1000: 1 tablet · As Needed\n'
        '  3 taken (Mar 4, 2026 – Mar 6, 2026)\n'
        'Notes: ging langsam weg',
      );
    });

    test('dates follow the labels\' locale, not Intl.defaultLocale', () {
      final previous = Intl.defaultLocale;
      addTearDown(() => Intl.defaultLocale = previous);
      Intl.defaultLocale = 'en';
      expect(summary('de'), contains('Krankheit: 2. März 2026'));
    });

    test('a treatment with no sick leave, doctor, medicines or notes is its '
        'name and dates only', () {
      expect(
        summary(
          'de',
          treatment: Treatment(
            id: 't2',
            name: 'Vitamin D',
            startDate: DateTime(2026, 3, 2),
          ),
          prescriptions: const [],
          doses: const [],
        ),
        'Vitamin D\n'
        'Krankheit: 2. März 2026 – Laufend',
      );
    });

    test('who was ill is named once, each name trimmed', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: 'Magen-Darm',
          startDate: DateTime(2026, 3, 2),
          patientTags: const [' Lena', 'Marco ', ''],
        ),
        prescriptions: const [],
        doses: const [],
      );
      expect(text.split('\n'), [
        'Magen-Darm',
        'Patient/in: Lena, Marco',
        'Krankheit: 2. März 2026 – Laufend',
      ]);
    });

    test('a treatment without patients names nobody', () {
      final text = summary(
        'en',
        treatment: Treatment(
          id: 't2',
          name: 'Flu',
          startDate: DateTime(2026, 3, 2),
        ),
        prescriptions: const [],
        doses: const [],
      );
      expect(text, isNot(contains('Patient')));
      expect(text, 'Flu\nIllness: Mar 2, 2026 – Ongoing');
    });

    test('blank certificate, doctor, patient and notes are left out', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: ' Grippe ',
          startDate: DateTime(2026, 3, 2),
          sickLeaveRef: '  ',
          doctor: '',
          notes: ' \n ',
          patientTags: const ['  '],
        ),
        prescriptions: const [],
        doses: const [],
      );
      expect(text, 'Grippe\nKrankheit: 2. März 2026 – Laufend');
    });

    test('an open leave counts its days so far', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 2),
          sickLeaveFrom: DateTime(2026, 3, 3),
        ),
        prescriptions: const [],
        doses: const [],
        now: DateTime(2026, 3, 5, 18),
      );
      expect(
        text.split('\n')[2],
        'Krankenstand: 3. März 2026 – Laufend (Tag 3)',
      );
    });

    test('an open leave that has not started names only its first day', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 2),
          sickLeaveFrom: DateTime(2026, 3, 20),
        ),
        prescriptions: const [],
        doses: const [],
        now: DateTime(2026, 3, 5),
      );
      expect(text.split('\n'), [
        'Grippe',
        'Krankheit: 2. März 2026 – Laufend',
        'Arbeitsunfähig von: 20. März 2026',
      ]);
    });

    test('a leave that ends before it starts shows its dates without a '
        'count', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 2),
          sickLeaveFrom: DateTime(2026, 3, 9),
          sickLeaveTo: DateTime(2026, 3, 3),
        ),
        prescriptions: const [],
        doses: const [],
      );
      expect(text.split('\n')[2], 'Krankenstand: 9. März 2026 – 3. März 2026');
    });

    test('an end date alone is shown as the last day', () {
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't2',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 2),
          sickLeaveTo: DateTime(2026, 3, 9),
        ),
        prescriptions: const [],
        doses: const [],
      );
      expect(text.split('\n')[2], 'Arbeitsunfähig bis: 9. März 2026');
    });

    test('a fixed interval, a missing name, a dose on one day, none taken '
        'and a schedule not begun', () {
      final every8h = Prescription(
        id: 'p3',
        treatmentId: 't1',
        medicationId: 'm3',
        dosage: '',
        startTime: DateTime(2026, 3, 3, 8),
      );
      final notBegun = Prescription(
        id: 'p4',
        treatmentId: 't1',
        medicationId: 'm4',
        dosage: '',
        durationDays: 1,
        startTime: DateTime(2026, 3, 20, 8),
        scheduleType: 'times_per_day',
        scheduleTimes: const ['08:00', '14:00', '20:00'],
        medicationName: 'Später',
      );
      final once = tachipirina.copyWith(dosage: '');
      final never = Prescription(
        id: 'p5',
        treatmentId: 't1',
        medicationId: 'm5',
        dosage: '',
        startTime: DateTime(2026, 3, 3, 8),
        scheduleType: 'as_needed',
        medicationName: 'Nie',
      );
      final l10n = lookupAppLocalizations(const Locale('de'));
      final text = buildEpisodeSummary(
        treatment: Treatment(
          id: 't1',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 2),
        ),
        prescriptions: [every8h, notBegun, once, never],
        doses: [
          DoseLog(
            id: 'x1',
            prescriptionId: 'p3',
            scheduledTime: DateTime(2026, 3, 3, 8),
            status: DoseStatus.taken,
          ),
          DoseLog(
            id: 'x2',
            prescriptionId: 'p3',
            scheduledTime: DateTime(2026, 3, 3, 16),
          ),
          DoseLog(
            id: 'x3',
            prescriptionId: 'p4',
            scheduledTime: DateTime(2026, 3, 20, 8),
          ),
          DoseLog(
            id: 'x4',
            prescriptionId: 'p2',
            scheduledTime: DateTime(2026, 3, 4, 15),
            takenTime: DateTime(2026, 3, 4, 15),
            status: DoseStatus.taken,
          ),
          DoseLog(
            id: 'x5',
            prescriptionId: 'p2',
            scheduledTime: DateTime(2026, 3, 4, 21),
            takenTime: DateTime(2026, 3, 4, 21),
            status: DoseStatus.taken,
          ),
        ],
        labels: EpisodeLabels.fromL10n(l10n),
        now: DateTime(2026, 3, 5),
        grace: Duration.zero,
        dosageText: (p) => p.dosage,
      );
      expect(
        text,
        'Grippe\n'
        'Krankheit: 2. März 2026 – Laufend\n'
        'Medikamente:\n'
        '- ${l10n.unknownMedication}: Alle 8 Stunden · 7 Tage\n'
        '  1 von 2 eingenommen\n'
        '- Später: 3 mal täglich · 1 Tag\n'
        '- Tachipirina 1000: Bei Bedarf\n'
        '  2 eingenommen (4. März 2026)\n'
        '- Nie: Bei Bedarf\n'
        '  Nicht eingenommen',
      );
    });

    test('an ended treatment expects none of its leftover doses', () {
      // Ended on Mar 4: the dose still pending from that evening was never
      // going to be taken, so it is not counted as missing.
      final text = summary(
        'de',
        treatment: Treatment(
          id: 't1',
          name: 'Grippe',
          startDate: DateTime(2026, 3, 3),
          endDate: DateTime(2026, 3, 4),
          isActive: false,
        ),
        prescriptions: [ibuprofen],
        doses: [
          DoseLog(
            id: 'e1',
            prescriptionId: 'p1',
            scheduledTime: DateTime(2026, 3, 4, 8),
            status: DoseStatus.taken,
          ),
          DoseLog(
            id: 'e2',
            prescriptionId: 'p1',
            scheduledTime: DateTime(2026, 3, 4, 20),
          ),
        ],
      );
      expect(text, endsWith('\n  1 von 1 eingenommen'));
    });

    test('a dose inside the grace period is not yet missing', () {
      final doses = [
        DoseLog(
          id: 'g1',
          prescriptionId: 'p1',
          scheduledTime: DateTime(2026, 3, 5, 8),
          status: DoseStatus.taken,
        ),
        DoseLog(
          id: 'g2',
          prescriptionId: 'p1',
          scheduledTime: DateTime(2026, 3, 5, 14),
        ),
      ];
      final running = Treatment(
        id: 't1',
        name: 'Grippe',
        startDate: DateTime(2026, 3, 5),
      );
      String at(DateTime now) => summary(
        'de',
        treatment: running,
        prescriptions: [ibuprofen],
        doses: doses,
        now: now,
        grace: const Duration(hours: 2),
      );
      // At 15:00 the 14:00 dose is still within its two hours.
      expect(at(DateTime(2026, 3, 5, 15)), endsWith('\n  1 von 1 eingenommen'));
      // At 16:00 it is due, and it was not taken.
      expect(at(DateTime(2026, 3, 5, 16)), endsWith('\n  1 von 2 eingenommen'));
    });

    test('none taken of what was due reads "0 of N", not nothing', () {
      final labels = labelsFor('de');
      final c = IntakeCount.of(
        ibuprofen,
        [
          for (var i = 0; i < 6; i++)
            DoseLog(
              id: 'n$i',
              prescriptionId: 'p1',
              scheduledTime: ibuprofen.scheduledDoseTimes[i],
              status: DoseStatus.missed,
            ),
        ],
        now: DateTime(2026, 3, 12),
        treatmentActive: true,
      );
      expect(intakeText(c, labels), '0 von 6 eingenommen');
      expect(intakeText(c, labelsFor('it')), '0 su 6 assunte');
      expect(intakeText(c, labelsFor('en')), '0 of 6 taken');
    });

    test('the share subject names the period, never the illness', () {
      expect(
        episodeShareSubject(sinusitis, labelsFor('de')),
        'Krankheitsverlauf: 2. März 2026 – 11. März 2026',
      );
      expect(
        episodeShareSubject(sinusitis, labelsFor('it')),
        'Decorso della malattia: 2 mar 2026 – 11 mar 2026',
      );
      final open = Treatment(
        id: 't2',
        name: 'Gastroenteritis',
        startDate: DateTime(2026, 3, 2),
      );
      final subject = episodeShareSubject(open, labelsFor('en'));
      expect(subject, 'Illness record: Mar 2, 2026 – Ongoing');
      expect(subject, isNot(contains('Gastroenteritis')));
    });

    test('on screen a date keeps together; in the shared text it does not', () {
      final l10n = lookupAppLocalizations(const Locale('de'));
      final screen = EpisodeLabels.fromL10n(l10n, keepDatesTogether: true);
      expect(screen.date(DateTime(2026, 3, 4)), '4.\u00A0März\u00A02026');
      expect(
        EpisodeLabels.fromL10n(l10n).date(DateTime(2026, 3, 4)),
        '4. März 2026',
      );
    });

    test('the intake line of a scheduled prescription', () {
      final labels = labelsFor('de');
      final c = IntakeCount.of(
        ibuprofen,
        sinusitisDoses,
        now: DateTime(2026, 3, 12),
        treatmentActive: false,
      );
      expect(intakeText(c, labels), '14 von 15 eingenommen');
    });
  });

  group('the treatment CSV', () {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final labels = ExportLabels.fromL10n(l10n);

    test('has the sick-leave columns after the existing ones', () {
      expect(labels.sickLeaveFrom, l10n.sickLeaveFrom);
      expect(labels.sickLeaveTo, l10n.sickLeaveTo);
      expect(labels.sickLeaveRef, l10n.sickLeaveRef);
      expect(labels.doctor, l10n.doctorLabel);

      final previous = Intl.defaultLocale;
      addTearDown(() => Intl.defaultLocale = previous);
      Intl.defaultLocale = 'de';
      final table = treatmentCsvTable([
        Treatment(
          id: 't1',
          name: 'Sinusitis',
          symptomTags: const ['Fieber'],
          startDate: DateTime(2026, 3, 2),
          endDate: DateTime(2026, 3, 11),
          isActive: false,
          notes: 'n',
          sickLeaveFrom: DateTime(2026, 3, 3),
          sickLeaveTo: DateTime(2026, 3, 9),
          sickLeaveRef: '1234567890',
          doctor: 'Dr. Rossi',
        ),
        Treatment(id: 't2', name: 'Vitamin D', startDate: DateTime(2026, 3, 2)),
      ], labels);

      expect(table[0], [
        l10n.name,
        l10n.symptoms,
        l10n.startDate,
        l10n.endDate,
        l10n.active,
        l10n.notes,
        l10n.sickLeaveFrom,
        l10n.sickLeaveTo,
        l10n.sickLeaveRef,
        l10n.doctorLabel,
      ]);
      expect(table[1], [
        'Sinusitis',
        'Fieber',
        '2. März 2026',
        '11. März 2026',
        l10n.noLabel,
        'n',
        '3. März 2026',
        '9. März 2026',
        '1234567890',
        'Dr. Rossi',
      ]);
      expect(table[2].sublist(6), ['', '', '', '']);
    });

    test('quotes commas, quotes and line breaks in the doctor, certificate '
        'and notes', () {
      const doctor = 'Dr. Rossi, "Studio Nord"';
      const ref = 'A,1"2';
      const notes = 'Zeile 1\nZeile 2, "zitiert"\r\nZeile 3';
      final table = treatmentCsvTable([
        Treatment(
          id: 't1',
          name: 'Sinusitis',
          startDate: DateTime(2026, 3, 2),
          notes: notes,
          sickLeaveRef: ref,
          doctor: doctor,
        ),
      ], labels);
      final csv = encodeCsv(table);

      expect(csv, contains('"Dr. Rossi, ""Studio Nord"""'));
      expect(csv, contains('"A,1""2"'));
      expect(csv, contains('"Zeile 1\nZeile 2, ""zitiert""\r\nZeile 3"'));
      // Read back, every field is whole and in its column.
      final rows = const CsvDecoder().convert(csv);
      expect(rows, hasLength(2));
      expect(rows[1], hasLength(10));
      expect(rows[1][5], notes);
      expect(rows[1][8], ref);
      expect(rows[1][9], doctor);
    });

    test('a cell a spreadsheet would run as a formula is written as text', () {
      final csv = encodeCsv([
        ['=HYPERLINK("http://x")', '+1', '-2 Tabletten', '@SUM(A1)', 'ok'],
        ['\t=1', '\r=1', 'a=b', '', 3],
        [-4, 'Dr. -Rossi'],
      ]);
      final rows = const CsvDecoder().convert(csv);
      expect(rows[0], [
        "'=HYPERLINK(\"http://x\")",
        "'+1",
        "'-2 Tabletten",
        "'@SUM(A1)",
        'ok',
      ]);
      expect(rows[1], ["'\t=1", "'\r=1", 'a=b', '', '3']);
      // A number is a value, not text a spreadsheet would run.
      expect(rows[2], ['-4', 'Dr. -Rossi']);
      expect(csv, endsWith('\r\n-4,Dr. -Rossi'));
    });

    test('the treatment CSV neutralises a formula in any text column', () {
      final table = treatmentCsvTable([
        Treatment(
          id: 't1',
          name: 'Sinusitis',
          startDate: DateTime(2026, 3, 2),
          notes: '- besser',
          doctor: '=HYPERLINK("http://x")',
        ),
      ], labels);
      final rows = const CsvDecoder().convert(encodeCsv(table));
      expect(rows[1][5], "'- besser");
      expect(rows[1][9], "'=HYPERLINK(\"http://x\")");
    });
  });
}
