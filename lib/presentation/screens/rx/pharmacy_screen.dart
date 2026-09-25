/// Medora - What the pharmacy scans: the prescription's Code 128 barcodes
/// and their values in large type, on a white page — the same barcodes,
/// with the same start/checksum/stop, as the ones printed on the paper.
library;

import 'package:flutter/material.dart';
import 'package:medora/presentation/widgets/code128.dart';

/// One barcode shown on [PharmacyScreen]: a label and the value it encodes.
class PharmacyCode {
  const PharmacyCode({required this.label, required this.value});
  final String label;
  final String value;
}

class PharmacyScreen extends StatelessWidget {
  const PharmacyScreen({super.key, required this.title, required this.codes});

  final String title;
  final List<PharmacyCode> codes;

  @override
  Widget build(BuildContext context) {
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
            for (var i = 0; i < codes.length; i++) ...[
              if (i > 0) const SizedBox(height: 32),
              _Label(codes[i].label),
              Code128Barcode(codes[i].value),
              Center(child: SelectableText(codes[i].value, style: big)),
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
