/// Medora - What the pharmacy scans: the prescription number and the tax
/// code, as barcodes and in large type, on a white page.
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/code39.dart';

class PharmacyScreen extends StatelessWidget {
  const PharmacyScreen({
    super.key,
    required this.nre,
    required this.taxCode,
    required this.title,
  });

  final String nre;
  final String? taxCode;
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const big = TextStyle(
      color: Colors.black,
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: 2,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(title),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          children: [
            _Label(l10n.rxNre),
            Code39Barcode(nre),
            Center(child: SelectableText(nre, style: big)),
            if (taxCode != null) ...[
              const SizedBox(height: 32),
              _Label(l10n.rxTaxCode),
              Code39Barcode(taxCode!),
              Center(child: SelectableText(taxCode!, style: big)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(text, style: const TextStyle(color: Colors.black54)),
  );
}
