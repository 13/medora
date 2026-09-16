/// Medora - Add/Edit Medication: the Stock & storage section.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';

/// The collapsible "Stock & storage" section: minimum stock, storage
/// location, purchase date and the barcode field with its lookup and scan
/// actions.
///
/// The form state stays with the screen: this takes the controllers it
/// draws and reports every edit back through a callback.
class MedicationStockSection extends StatelessWidget {
  const MedicationStockSection({
    super.key,
    required this.minStockController,
    required this.storageLocationController,
    required this.barcodeController,
    required this.expanded,
    required this.summary,
    required this.purchaseDate,
    required this.now,
    required this.hasCamera,
    required this.onMinStockChanged,
    required this.onStorageChanged,
    required this.onPurchaseDateSelected,
    required this.onSearchBarcode,
    required this.onScan,
    required this.onBarcodeChanged,
    required this.onBarcodeSubmitted,
  });

  final TextEditingController minStockController;
  final TextEditingController storageLocationController;
  final TextEditingController barcodeController;

  /// Two-way expansion, owned by the screen (see [FormSection.controller]).
  final ValueNotifier<bool> expanded;

  /// What the header shows while the section is collapsed.
  final String summary;

  final DateTime? purchaseDate;
  final DateTime now;
  final bool hasCamera;

  final VoidCallback onMinStockChanged;
  final ValueChanged<String?> onStorageChanged;
  final ValueChanged<DateTime?> onPurchaseDateSelected;
  final ValueChanged<String> onSearchBarcode;
  final VoidCallback onScan;
  final ValueChanged<String> onBarcodeChanged;
  final ValueChanged<String> onBarcodeSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FormSection(
      title: l10n.sectionStock,
      icon: Icons.inventory_2,
      initiallyExpanded: false,
      controller: expanded,
      summary: summary,
      children: [
        TextFormField(
          controller: minStockController,
          decoration: InputDecoration(
            labelText: l10n.minStock,
            prefixIcon: const Icon(Icons.low_priority),
          ),
          keyboardType: TextInputType.number,
          onChanged: (_) => onMinStockChanged(),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey('loc_${storageLocationController.text}'),
          initialValue:
              AppConstants.storageLocationKeys.contains(
                storageLocationController.text,
              )
              ? storageLocationController.text
              : null,
          decoration: InputDecoration(
            labelText: l10n.storageLocation,
            prefixIcon: const Icon(Icons.place),
          ),
          items: AppConstants.storageLocationKeys.map((key) {
            return DropdownMenuItem(
              value: key,
              child: Text(AppConstants.storageLabel(l10n, key)),
            );
          }).toList(),
          onChanged: onStorageChanged,
        ),
        const SizedBox(height: 16),
        DatePickerField(
          label: l10n.purchaseDate,
          icon: Icons.shopping_cart,
          date: purchaseDate,
          now: now,
          onDateSelected: onPurchaseDateSelected,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: barcodeController,
          decoration: InputDecoration(
            labelText: l10n.barcode,
            prefixIcon: const Icon(Icons.qr_code),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search MyHealthBox by barcode text
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: l10n.searchByBarcode,
                  onPressed: barcodeController.text.trim().isNotEmpty
                      ? () => onSearchBarcode(barcodeController.text.trim())
                      : null,
                ),
                // Open camera scanner
                if (hasCamera)
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: l10n.scanBarcodeTooltip,
                    onPressed: onScan,
                  ),
              ],
            ),
          ),
          onChanged: onBarcodeChanged,
          onFieldSubmitted: onBarcodeSubmitted,
        ),
      ],
    );
  }
}
