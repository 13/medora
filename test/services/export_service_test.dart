import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/export_service.dart';

void main() {
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
}
