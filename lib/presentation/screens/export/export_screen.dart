/// Medora - Export Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/services/export_service.dart';
import 'package:share_plus/share_plus.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _includeMedications = true;
  bool _includeTreatments = true;
  bool _includeDoseLogs = true;
  ExportFormat _format = ExportFormat.pdf;
  bool _isExporting = false;

  // Date range for dose logs
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    _endDate = DateTime.now();
    _startDate = _endDate.subtract(const Duration(days: 30));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.exportDataTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header
          Card(
            color: AppTheme.primaryColor.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.download_outlined,
                      color: AppTheme.primaryColor, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.exportYourData,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          l10n.chooseWhatToExport,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Data selection
          Text(
            l10n.include,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            title: Text(l10n.medications),
            subtitle: Text(l10n.fullMedicationInventory),
            value: _includeMedications,
            onChanged: (v) => setState(() => _includeMedications = v ?? true),
          ),
          CheckboxListTile(
            title: Text(l10n.treatments),
            subtitle: Text(l10n.treatmentPlansAndHistory),
            value: _includeTreatments,
            onChanged: (v) => setState(() => _includeTreatments = v ?? true),
          ),
          CheckboxListTile(
            title: Text(l10n.doseLogs),
            subtitle: Text(l10n.medicationIntakeRecords),
            value: _includeDoseLogs,
            onChanged: (v) => setState(() => _includeDoseLogs = v ?? true),
          ),
          const SizedBox(height: 16),

          // Date range for dose logs
          if (_includeDoseLogs) ...[
            Text(
              l10n.doseLogDateRange,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _startDate,
                        firstDate: DateTime(2020),
                        lastDate: _endDate,
                      );
                      if (picked != null) setState(() => _startDate = picked);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: l10n.from,
                        prefixIcon: const Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(
                        '${_startDate.year}-${_startDate.month.toString().padLeft(2, '0')}-${_startDate.day.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _endDate,
                        firstDate: _startDate,
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setState(() => _endDate = picked);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: l10n.to,
                        prefixIcon: const Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(
                        '${_endDate.year}-${_endDate.month.toString().padLeft(2, '0')}-${_endDate.day.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Format selection
          Text(
            l10n.format,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(
                value: ExportFormat.pdf,
                label: Text('PDF'),
                icon: Icon(Icons.picture_as_pdf),
              ),
              ButtonSegment(
                value: ExportFormat.csv,
                label: Text('CSV'),
                icon: Icon(Icons.table_chart),
              ),
            ],
            selected: {_format},
            onSelectionChanged: (v) => setState(() => _format = v.first),
          ),
          const SizedBox(height: 32),

          // Export button
          SizedBox(
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _isExporting ||
                      (!_includeMedications &&
                          !_includeTreatments &&
                          !_includeDoseLogs)
                  ? null
                  : _export,
              icon: _isExporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.share),
              label: Text(_isExporting ? l10n.exporting : l10n.exportAndShare),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);

    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export is not yet supported on Web.')),
      );
      return;
    }

    setState(() => _isExporting = true);

    try {
      final exportService = ExportService.instance;

      List<Medication>? medications;
      List<Treatment>? treatments;
      List<DoseLog>? doseLogs;

      if (_includeMedications) {
        final medsAsync = ref.read(medicationListProvider);
        medications = medsAsync.value ?? [];
      }

      if (_includeTreatments) {
        final treatsAsync = ref.read(treatmentListProvider);
        treatments = treatsAsync.value ?? [];
      }

      if (_includeDoseLogs) {
        final repo = ref.read(doseLogRepositoryProvider);
        final result = await repo.getDoseLogsByDateRange(
          _startDate,
          _endDate.add(const Duration(days: 1)),
        );
        doseLogs = result.when(
          success: (logs) => logs,
          failure: (_, [_]) => <DoseLog>[],
        );
      }

      if (_format == ExportFormat.pdf) {
        final file = await exportService.exportPDF(
          medications: medications,
          treatments: treatments,
          doseLogs: doseLogs,
        );
        if (file != null) {
          await SharePlus.instance.share(
            ShareParams(files: [XFile(file.path)]),
          );
        }
      } else {
        final files = <XFile>[];

        if (medications != null && medications.isNotEmpty) {
          final f = await exportService.exportMedicationsCSV(medications);
          if (f != null) files.add(XFile(f.path));
        }
        if (treatments != null && treatments.isNotEmpty) {
          final f = await exportService.exportTreatmentsCSV(treatments);
          if (f != null) files.add(XFile(f.path));
        }
        if (doseLogs != null && doseLogs.isNotEmpty) {
          final f = await exportService.exportDoseLogsCSV(doseLogs);
          if (f != null) files.add(XFile(f.path));
        }

        if (files.isNotEmpty) {
          await SharePlus.instance.share(
            ShareParams(files: files),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.noDataToExport)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.exportFailed(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}


enum ExportFormat { pdf, csv }
