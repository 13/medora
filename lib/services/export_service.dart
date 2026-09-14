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
import 'package:medora/domain/entities/medication.dart';
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

  /// Localized label for a dose's status column, e.g. "Skipped" — never
  /// [DoseStatus.name], which is the raw untranslated enum value.
  String statusLabel(DoseStatus status) => switch (status) {
    DoseStatus.taken => doseTaken,
    DoseStatus.skipped => doseSkipped,
    DoseStatus.missed => doseMissed,
    DoseStatus.pending => dosePending,
  };
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
  ) async {
    final headers = [
      labels.name,
      labels.symptoms,
      labels.startDate,
      labels.endDate,
      labels.active,
      labels.notes,
    ];

    final rows = treatments.map(
      (t) => [
        t.name,
        t.symptomTags.join(', '),
        t.startDate.formatted,
        t.endDate != null ? t.endDate!.formatted : '',
        t.isActive ? labels.yes : labels.no,
        t.notes ?? '',
      ],
    );

    return _writeCSV('medora_treatments', [headers, ...rows]);
  }

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

    final csv = const CsvEncoder().convert(data);
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
