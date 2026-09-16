/// Medora - Export Service
///
/// Generates CSV and PDF exports of medication, treatment, and dose data.
library;

import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:intl/intl.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/intake_count.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Localized labels used to build CSV headers and PDF section titles.
///
/// Built from [AppLocalizations] by the caller so this service stays
/// free of [BuildContext].
class ExportLabels {
  const ExportLabels({
    required this.reportTitle,
    required this.summary,
    required this.medications,
    required this.treatments,
    required this.doseLog,
    required this.yes,
    required this.no,
    required this.active,
    required this.ended,
    // column headers:
    required this.name,
    required this.activeIngredient,
    required this.category,
    required this.quantity,
    required this.minStock,
    required this.purchaseDate,
    required this.expiryDate,
    required this.storageLocation,
    required this.barcode,
    required this.notes,
    required this.symptoms,
    required this.startDate,
    required this.endDate,
    required this.medication,
    required this.dosage,
    required this.scheduledTime,
    required this.takenTime,
    required this.status,
    required this.doseTaken,
    required this.doseSkipped,
    required this.doseMissed,
    required this.dosePending,
    required this.sickLeaveFrom,
    required this.sickLeaveTo,
    required this.sickLeaveRef,
    required this.doctor,
  });

  factory ExportLabels.fromL10n(AppLocalizations l10n) => ExportLabels(
    reportTitle: l10n.exportReportTitle,
    summary: l10n.exportSummary,
    medications: l10n.medications,
    treatments: l10n.treatments,
    doseLog: l10n.exportDoseRecords,
    yes: l10n.yesLabel,
    no: l10n.noLabel,
    active: l10n.active,
    ended: l10n.ended,
    name: l10n.name,
    activeIngredient: l10n.colActiveIngredient,
    category: l10n.category,
    quantity: l10n.quantity,
    minStock: l10n.colMinStock,
    purchaseDate: l10n.purchaseDate,
    expiryDate: l10n.expiryDate,
    storageLocation: l10n.storageLocation,
    barcode: l10n.barcode,
    notes: l10n.notes,
    symptoms: l10n.symptoms,
    startDate: l10n.startDate,
    endDate: l10n.endDate,
    medication: l10n.medication,
    dosage: l10n.dosage,
    scheduledTime: l10n.colScheduled,
    takenTime: l10n.colTaken,
    status: l10n.colStatus,
    doseTaken: l10n.taken,
    doseSkipped: l10n.skipped,
    doseMissed: l10n.missed,
    dosePending: l10n.pending,
    sickLeaveFrom: l10n.sickLeaveFrom,
    sickLeaveTo: l10n.sickLeaveTo,
    sickLeaveRef: l10n.sickLeaveRef,
    doctor: l10n.doctorLabel,
  );

  final String reportTitle;
  final String summary;
  final String medications;
  final String treatments;
  final String doseLog;
  final String yes;
  final String no;
  final String active;
  final String ended;
  final String name;
  final String activeIngredient;
  final String category;
  final String quantity;
  final String minStock;
  final String purchaseDate;
  final String expiryDate;
  final String storageLocation;
  final String barcode;
  final String notes;
  final String symptoms;
  final String startDate;
  final String endDate;
  final String medication;
  final String dosage;
  final String scheduledTime;
  final String takenTime;
  final String status;
  final String doseTaken;
  final String doseSkipped;
  final String doseMissed;
  final String dosePending;
  final String sickLeaveFrom;
  final String sickLeaveTo;
  final String sickLeaveRef;
  final String doctor;

  /// Localized label for a dose's status column, e.g. "Skipped" — never
  /// [DoseStatus.name], which is the raw untranslated enum value.
  String statusLabel(DoseStatus status) => switch (status) {
    DoseStatus.taken => doseTaken,
    DoseStatus.skipped => doseSkipped,
    DoseStatus.missed => doseMissed,
    DoseStatus.pending => dosePending,
  };
}

/// The treatment CSV: a header row, then one row per treatment. Split out of
/// [ExportService.exportTreatmentsCSV] so it is testable without a file.
@visibleForTesting
List<List<String>> treatmentCsvTable(
  List<Treatment> treatments,
  ExportLabels labels,
) => [
  [
    labels.name,
    labels.symptoms,
    labels.startDate,
    labels.endDate,
    labels.active,
    labels.notes,
    labels.sickLeaveFrom,
    labels.sickLeaveTo,
    labels.sickLeaveRef,
    labels.doctor,
  ],
  for (final t in treatments)
    [
      t.name,
      t.symptomTags.join(', '),
      t.startDate.formatted,
      t.endDate?.formatted ?? '',
      t.isActive ? labels.yes : labels.no,
      t.notes ?? '',
      t.sickLeaveFrom?.formatted ?? '',
      t.sickLeaveTo?.formatted ?? '',
      t.sickLeaveRef ?? '',
      t.doctor ?? '',
    ],
];

/// [rows] as CSV text. A field holding a comma, a quote or a line break is
/// quoted, with its quotes doubled (RFC 4180), so free text such as a
/// doctor's "Dr. Rossi, Bolzano" stays in its column.
///
/// Every export goes through here, so this is where text a spreadsheet
/// would run as a formula is disarmed: a text cell that starts with `=`,
/// `+`, `-`, `@`, a tab or a carriage return gets a leading `'` (the OWASP
/// rule), so `=HYPERLINK(…)` pasted into a doctor's name or a note opens as
/// text. Numbers are left alone.
@visibleForTesting
String encodeCsv(List<List<dynamic>> rows) => const CsvEncoder().convert([
  for (final row in rows) [for (final cell in row) _inertCell(cell)],
]);

dynamic _inertCell(dynamic cell) =>
    cell is String && cell.startsWith(_formulaStart) ? "'$cell" : cell;

final _formulaStart = RegExp(r'[=+\-@\t\r]');

/// Localized labels for the one-episode text share, mirroring
/// [ExportLabels.fromL10n] so this service stays free of [BuildContext].
class EpisodeLabels {
  const EpisodeLabels({
    required this.patient,
    required this.subject,
    required this.illness,
    required this.sickLeave,
    required this.sickLeaveFrom,
    required this.sickLeaveTo,
    required this.sickLeaveRef,
    required this.doctor,
    required this.symptoms,
    required this.medications,
    required this.notes,
    required this.ongoing,
    required this.asNeeded,
    required this.unknownMedication,
    required this.days,
    required this.day,
    required this.everyHours,
    required this.timesDaily,
    required this.takenOfDue,
    required this.takenAsNeeded,
    required this.date,
  });

  /// [keepDatesTogether] joins the words of each date with no-break spaces,
  /// so a line on screen never wraps inside one ("4. März / 2026"). The
  /// shared text keeps plain spaces.
  factory EpisodeLabels.fromL10n(
    AppLocalizations l10n, {
    bool keepDatesTogether = false,
  }) {
    // The labels' own locale, not Intl.defaultLocale: the text is one piece.
    final dateFormat = DateFormat.yMMMd(l10n.localeName);
    return EpisodeLabels(
      patient: l10n.episodePatient,
      subject: l10n.episodeShareSubject,
      illness: l10n.illness,
      sickLeave: l10n.sickLeavePeriod,
      sickLeaveFrom: l10n.sickLeaveFrom,
      sickLeaveTo: l10n.sickLeaveTo,
      sickLeaveRef: l10n.sickLeaveRef,
      doctor: l10n.doctorLabel,
      symptoms: l10n.symptoms,
      medications: l10n.medications,
      notes: l10n.notes,
      ongoing: l10n.ongoing,
      asNeeded: l10n.scheduleAsNeeded,
      unknownMedication: l10n.unknownMedication,
      days: l10n.sickLeaveDays,
      day: l10n.sickLeaveDay,
      everyHours: l10n.everyXHours,
      timesDaily: l10n.xTimesDaily,
      takenOfDue: l10n.dosesTakenOfPlanned,
      takenAsNeeded: l10n.dosesTakenAsNeeded,
      date: keepDatesTogether
          ? (d) => dateFormat.format(d).replaceAll(' ', '\u00A0')
          : dateFormat.format,
    );
  }

  /// Label of the line naming who was ill.
  final String patient;

  /// The share's subject, around the illness period.
  final String Function(String period) subject;
  final String illness;
  final String sickLeave;
  final String sickLeaveFrom;
  final String sickLeaveTo;
  final String sickLeaveRef;
  final String doctor;
  final String symptoms;
  final String medications;
  final String notes;
  final String ongoing;
  final String asNeeded;
  final String unknownMedication;

  /// "7 days": a number of calendar days.
  final String Function(int days) days;

  /// "Day 3": the running day of an open sick leave.
  final String Function(int day) day;
  final String Function(int hours) everyHours;
  final String Function(int count) timesDaily;
  final String Function(int taken, int due) takenOfDue;
  final String Function(int taken) takenAsNeeded;

  /// A calendar date in the labels' locale ("5. März 2026").
  final String Function(DateTime date) date;
}

/// The intake line of one prescription: "14 of 15 taken", or for an
/// as-needed one "3 taken (Mar 4, 2026 – Mar 6, 2026)". Null for a schedule
/// with nothing due yet, where a count would only say "0 of 0".
String? intakeText(IntakeCount count, EpisodeLabels labels) {
  if (count.asNeeded) {
    final taken = labels.takenAsNeeded(count.taken);
    final first = count.firstTaken;
    final last = count.lastTaken;
    if (first == null || last == null) return taken;
    final from = labels.date(first);
    final to = labels.date(last);
    return from == to ? '$taken ($from)' : '$taken ($from – $to)';
  }
  if (count.due == 0) return null;
  return labels.takenOfDue(count.taken, count.due);
}

/// The illness period of [treatment]: "Mar 2, 2026 – Ongoing".
String _illnessPeriod(Treatment treatment, EpisodeLabels labels) {
  final end = treatment.endDate;
  return '${labels.date(treatment.startDate)} – '
      '${end == null ? labels.ongoing : labels.date(end)}';
}

/// The subject of a shared episode: "Illness record: Mar 2, 2026 – Mar 11,
/// 2026". It never names the illness, since mail lists, notifications and
/// message previews show the subject to anyone who glances at the screen.
String episodeShareSubject(Treatment treatment, EpisodeLabels labels) =>
    labels.subject(_illnessPeriod(treatment, labels));

/// A plain-text record of one illness episode, for
/// `SharePlus.instance.share(ShareParams(text: …))`.
///
/// One episode, never the cabinet: the user hands an employer or a doctor
/// this illness, its sick leave and what was taken for it, not their whole
/// medicine history. It holds no ids and no sync state, and leaves out every
/// field that is not set. [doses] may hold other prescriptions' doses; only
/// those of [prescriptions] are counted, as of [now], with [grace] as the
/// app's missed-dose grace period (see [IntakeCount.of]). The patients are
/// named when the treatment has any: in a household the reader could not
/// otherwise tell whose record it is.
///
/// Pure, so it is unit-testable without a share sheet. [dosageText] formats
/// a prescription's dose: the caller passes `prescriptionDosageLabel`, which
/// lives in the presentation layer.
String buildEpisodeSummary({
  required Treatment treatment,
  required List<Prescription> prescriptions,
  required List<DoseLog> doses,
  required EpisodeLabels labels,
  required DateTime now,
  required Duration grace,
  required String Function(Prescription) dosageText,
}) {
  final date = labels.date;
  String? text(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final patients = [for (final tag in treatment.patientTags) ?text(tag)];
  final lines = <String>[
    treatment.name.trim(),
    if (patients.isNotEmpty) '${labels.patient}: ${patients.join(', ')}',
    '${labels.illness}: ${_illnessPeriod(treatment, labels)}',
  ];

  final from = treatment.sickLeaveFrom;
  final to = treatment.sickLeaveTo;
  final days = treatment.sickLeaveDaysAt(now);
  if (from != null && (to != null || days != null)) {
    final count = days == null
        ? ''
        : ' (${to == null ? labels.day(days) : labels.days(days)})';
    lines.add(
      '${labels.sickLeave}: ${date(from)} – '
      '${to == null ? labels.ongoing : date(to)}$count',
    );
  } else if (from != null) {
    // An open leave that has not begun: only its first day is known.
    lines.add('${labels.sickLeaveFrom}: ${date(from)}');
  } else if (to != null) {
    // Only a synced or restored row carries an end without a start.
    lines.add('${labels.sickLeaveTo}: ${date(to)}');
  }
  final ref = text(treatment.sickLeaveRef);
  if (ref != null) lines.add('${labels.sickLeaveRef}: $ref');
  final doctor = text(treatment.doctor);
  if (doctor != null) lines.add('${labels.doctor}: $doctor');
  if (treatment.symptomTags.isNotEmpty) {
    lines.add('${labels.symptoms}: ${treatment.symptomTags.join(', ')}');
  }

  if (prescriptions.isNotEmpty) {
    lines.add('${labels.medications}:');
    for (final p in prescriptions) {
      final schedule = switch (p.scheduleType) {
        'as_needed' => [labels.asNeeded],
        _ => [
          if (p.scheduleType == 'times_per_day' &&
              (p.scheduleTimes?.isNotEmpty ?? false))
            labels.timesDaily(p.scheduleTimes!.length)
          else
            labels.everyHours(p.intervalHours),
          if (p.durationDays > 0) labels.days(p.durationDays),
        ],
      };
      final parts = [?text(dosageText(p)), ...schedule].join(' · ');
      final name = text(p.medicationName) ?? labels.unknownMedication;
      lines.add('- $name: $parts');
      final intake = intakeText(
        IntakeCount.of(
          p,
          doses,
          now: now,
          treatmentActive: treatment.isActive,
          grace: grace,
        ),
        labels,
      );
      if (intake != null) lines.add('  $intake');
    }
  }

  final notes = text(treatment.notes);
  if (notes != null) lines.add('${labels.notes}: $notes');

  return lines.join('\n');
}

/// A dose log's row for the CSV export — [ExportService.exportDoseLogsCSV]'s
/// values, split out so the status localization is testable without writing
/// a file.
@visibleForTesting
List<String> doseLogCsvRow(DoseLog d, ExportLabels labels) => [
  d.medicationName ?? '',
  d.dosage ?? '',
  d.scheduledTime.dateTimeFormatted,
  d.takenTime != null ? d.takenTime!.dateTimeFormatted : '',
  labels.statusLabel(d.status),
  d.notes ?? '',
];

/// A dose log's row for the PDF export's dose-log table — the [doseLogCsvRow]
/// twin for [ExportService.exportPDF].
@visibleForTesting
List<String> doseLogPdfRow(DoseLog d, ExportLabels labels) => [
  d.medicationName ?? '—',
  d.scheduledTime.dateTimeFormatted,
  d.takenTime != null ? d.takenTime!.dateTimeFormatted : '—',
  labels.statusLabel(d.status),
];

class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  // ═══════════════════════════════════════════════════════════
  // CSV EXPORTS
  // ═══════════════════════════════════════════════════════════

  /// Export medications as CSV file.
  Future<File?> exportMedicationsCSV(
    List<Medication> medications,
    ExportLabels labels,
  ) async {
    final headers = [
      labels.name,
      labels.activeIngredient,
      labels.category,
      labels.quantity,
      labels.minStock,
      labels.purchaseDate,
      labels.expiryDate,
      labels.storageLocation,
      labels.barcode,
      labels.notes,
    ];

    final rows = medications.map(
      (m) => [
        m.name,
        m.activeIngredients.join(', '),
        m.category ?? '',
        m.quantity,
        m.minimumStockLevel,
        m.purchaseDate != null ? m.purchaseDate!.formatted : '',
        m.expiryDate != null ? m.expiryDate!.formatted : '',
        m.storageLocation ?? '',
        m.barcode ?? '',
        m.notes ?? '',
      ],
    );

    return _writeCSV('medora_medications', [headers, ...rows]);
  }

  /// Export treatments as CSV file.
  Future<File?> exportTreatmentsCSV(
    List<Treatment> treatments,
    ExportLabels labels,
  ) async =>
      _writeCSV('medora_treatments', treatmentCsvTable(treatments, labels));

  /// Export dose logs as CSV file.
  Future<File?> exportDoseLogsCSV(
    List<DoseLog> doseLogs,
    ExportLabels labels,
  ) async {
    final headers = [
      labels.medication,
      labels.dosage,
      labels.scheduledTime,
      labels.takenTime,
      labels.status,
      labels.notes,
    ];

    final rows = doseLogs.map((d) => doseLogCsvRow(d, labels));

    return _writeCSV('medora_dose_logs', [headers, ...rows]);
  }

  Future<File?> _writeCSV(String name, List<List<dynamic>> data) async {
    if (kIsWeb) return null; // Web needs a different download strategy

    final csv = encodeCsv(data);
    final dir = await getTemporaryDirectory();
    final timestamp = DateFormat(
      'yyyyMMdd_HHmm',
    ).format(DateTime.now()); // l10n-exempt: filename
    final file = File('${dir.path}/${name}_$timestamp.csv');
    await file.writeAsString(csv);
    return file;
  }

  // ═══════════════════════════════════════════════════════════
  // PDF EXPORT
  // ═══════════════════════════════════════════════════════════

  /// Export a combined PDF report.
  Future<File?> exportPDF({
    List<Medication>? medications,
    List<Treatment>? treatments,
    List<DoseLog>? doseLogs,
    required ExportLabels labels,
  }) async {
    if (kIsWeb) return null; // Web needs a different download strategy

    final pdf = pw.Document(
      title: labels.reportTitle,
      author: 'Medora App', // l10n-exempt: proper noun
    );

    // Title page
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    labels.reportTitle,
                    style: const pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    DateTime.now().formatted,
                    style: const pw.TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(labels.summary, style: const pw.TextStyle(fontSize: 14)),
            pw.Divider(),
            pw.SizedBox(height: 12),
            if (medications != null)
              pw.Text('${labels.medications}: ${medications.length}'),
            if (treatments != null)
              pw.Text('${labels.treatments}: ${treatments.length}'),
            if (doseLogs != null)
              pw.Text('${labels.doseLog}: ${doseLogs.length}'),
          ],
        ),
      ),
    );

    // Medications table
    if (medications != null && medications.isNotEmpty) {
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          header: (context) => pw.Header(child: pw.Text(labels.medications)),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellHeight: 28,
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.centerLeft,
                2: pw.Alignment.center,
                3: pw.Alignment.centerLeft,
                4: pw.Alignment.centerLeft,
              },
              headers: [
                labels.name,
                labels.category,
                labels.quantity,
                labels.expiryDate,
                labels.storageLocation,
              ],
              data: medications
                  .map(
                    (m) => [
                      m.name,
                      m.category ?? '—',
                      '${m.quantity}',
                      m.expiryDate != null ? m.expiryDate!.formatted : '—',
                      m.storageLocation ?? '—',
                    ],
                  )
                  .toList(),
            ),
          ],
        ),
      );
    }

    // Treatments table
    if (treatments != null && treatments.isNotEmpty) {
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          header: (context) => pw.Header(child: pw.Text(labels.treatments)),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellHeight: 28,
              headers: [
                labels.name,
                labels.symptoms,
                labels.startDate,
                labels.endDate,
                labels.status,
              ],
              data: treatments
                  .map(
                    (t) => [
                      t.name,
                      t.symptomTags.isNotEmpty ? t.symptomTags.join(', ') : '—',
                      t.startDate.formatted,
                      t.endDate != null ? t.endDate!.formatted : '—',
                      t.isActive ? labels.active : labels.ended,
                    ],
                  )
                  .toList(),
            ),
          ],
        ),
      );
    }

    // Dose logs table
    if (doseLogs != null && doseLogs.isNotEmpty) {
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          header: (context) => pw.Header(child: pw.Text(labels.doseLog)),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey200,
              ),
              cellHeight: 28,
              headers: [
                labels.medication,
                labels.scheduledTime,
                labels.takenTime,
                labels.status,
              ],
              data: doseLogs.map((d) => doseLogPdfRow(d, labels)).toList(),
            ),
          ],
        ),
      );
    }

    final dir = await getTemporaryDirectory();
    final timestamp = DateFormat(
      'yyyyMMdd_HHmm',
    ).format(DateTime.now()); // l10n-exempt: filename
    final file = File('${dir.path}/medora_report_$timestamp.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }
}
