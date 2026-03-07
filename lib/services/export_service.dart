/// Medora - Export Service
///
/// Generates CSV and PDF exports of medication, treatment, and dose data.
library;

import 'dart:io';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';

class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  final _dateFormat = DateFormat('yyyy-MM-dd');
  final _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm');

  // ═══════════════════════════════════════════════════════════
  // CSV EXPORTS
  // ═══════════════════════════════════════════════════════════

  /// Export medications as CSV file.
  Future<File> exportMedicationsCSV(List<Medication> medications) async {
    final headers = [
      'Name',
      'Active Ingredient',
      'Category',
      'Quantity',
      'Min Stock',
      'Purchase Date',
      'Expiry Date',
      'Storage Location',
      'Barcode',
      'Notes',
    ];

    final rows = medications.map((m) => [
          m.name,
          m.activeIngredients.join(', '),
          m.category ?? '',
          m.quantity,
          m.minimumStockLevel,
          m.purchaseDate != null ? _dateFormat.format(m.purchaseDate!) : '',
          m.expiryDate != null ? _dateFormat.format(m.expiryDate!) : '',
          m.storageLocation ?? '',
          m.barcode ?? '',
          m.notes ?? '',
        ]);

    return _writeCSV('medora_medications', [headers, ...rows]);
  }

  /// Export treatments as CSV file.
  Future<File> exportTreatmentsCSV(List<Treatment> treatments) async {
    final headers = [
      'Name',
      'Symptoms',
      'Start Date',
      'End Date',
      'Active',
      'Notes',
    ];

    final rows = treatments.map((t) => [
          t.name,
          t.symptomTags.join(', '),
          _dateFormat.format(t.startDate),
          t.endDate != null ? _dateFormat.format(t.endDate!) : '',
          t.isActive ? 'Yes' : 'No',
          t.notes ?? '',
        ]);

    return _writeCSV('medora_treatments', [headers, ...rows]);
  }

  /// Export dose logs as CSV file.
  Future<File> exportDoseLogsCSV(List<DoseLog> doseLogs) async {
    final headers = [
      'Medication',
      'Dosage',
      'Scheduled Time',
      'Taken Time',
      'Status',
      'Notes',
    ];

    final rows = doseLogs.map((d) => [
          d.medicationName ?? '',
          d.dosage ?? '',
          _dateTimeFormat.format(d.scheduledTime),
          d.takenTime != null ? _dateTimeFormat.format(d.takenTime!) : '',
          d.status.name,
          d.notes ?? '',
        ]);

    return _writeCSV('medora_dose_logs', [headers, ...rows]);
  }

  Future<File> _writeCSV(String name, List<List<dynamic>> data) async {
    final csv = const CsvEncoder().convert(data);
    final dir = await getTemporaryDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final file = File('${dir.path}/${name}_$timestamp.csv');
    await file.writeAsString(csv);
    return file;
  }

  // ═══════════════════════════════════════════════════════════
  // PDF EXPORT
  // ═══════════════════════════════════════════════════════════

  /// Export a combined PDF report.
  Future<File> exportPDF({
    List<Medication>? medications,
    List<Treatment>? treatments,
    List<DoseLog>? doseLogs,
  }) async {
    final pdf = pw.Document(
      title: 'Medora Report',
      author: 'Medora App',
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
                  pw.Text('Medora Report',
                      style: pw.TextStyle(
                          fontSize: 24, fontWeight: pw.FontWeight.bold)),
                  pw.Text(
                    _dateFormat.format(DateTime.now()),
                    style: const pw.TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Home Medicine Cabinet Summary',
              style: const pw.TextStyle(fontSize: 14),
            ),
            pw.Divider(),
            pw.SizedBox(height: 12),
            if (medications != null)
              pw.Text('Medications: ${medications.length}'),
            if (treatments != null)
              pw.Text('Treatments: ${treatments.length}'),
            if (doseLogs != null)
              pw.Text('Dose Records: ${doseLogs.length}'),
          ],
        ),
      ),
    );

    // Medications table
    if (medications != null && medications.isNotEmpty) {
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          header: (context) => pw.Header(
            level: 1,
            child: pw.Text('Medications'),
          ),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.grey200),
              cellHeight: 28,
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.centerLeft,
                2: pw.Alignment.center,
                3: pw.Alignment.centerLeft,
                4: pw.Alignment.centerLeft,
              },
              headers: [
                'Name',
                'Category',
                'Qty',
                'Expiry',
                'Location'
              ],
              data: medications
                  .map((m) => [
                        m.name,
                        m.category ?? '—',
                        '${m.quantity}',
                        m.expiryDate != null
                            ? _dateFormat.format(m.expiryDate!)
                            : '—',
                        m.storageLocation ?? '—',
                      ])
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
          header: (context) => pw.Header(
            level: 1,
            child: pw.Text('Treatments'),
          ),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.grey200),
              cellHeight: 28,
              headers: ['Name', 'Symptoms', 'Start', 'End', 'Status'],
              data: treatments
                  .map((t) => [
                        t.name,
                        t.symptomTags.isNotEmpty ? t.symptomTags.join(', ') : '—',
                        _dateFormat.format(t.startDate),
                        t.endDate != null
                            ? _dateFormat.format(t.endDate!)
                            : '—',
                        t.isActive ? 'Active' : 'Ended',
                      ])
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
          header: (context) => pw.Header(
            level: 1,
            child: pw.Text('Dose Log'),
          ),
          build: (context) => [
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.grey200),
              cellHeight: 28,
              headers: [
                'Medication',
                'Scheduled',
                'Taken',
                'Status'
              ],
              data: doseLogs
                  .map((d) => [
                        d.medicationName ?? '—',
                        _dateTimeFormat.format(d.scheduledTime),
                        d.takenTime != null
                            ? _dateTimeFormat.format(d.takenTime!)
                            : '—',
                        d.status.name,
                      ])
                  .toList(),
            ),
          ],
        ),
      );
    }

    final dir = await getTemporaryDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final file = File('${dir.path}/medora_report_$timestamp.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }
}

