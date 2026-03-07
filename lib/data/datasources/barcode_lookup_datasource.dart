/// Medora - AIFA Medication Lookup Datasource
///
/// Searches the Italian AIFA medication database (confezioni.csv)
/// by AIC code (the number found on Italian medication packages).
///
/// CSV source: https://drive.aifa.gov.it/farmaci/confezioni.csv
/// Format: semicolon-separated, no header row.
/// Fields: code;groupCode;variantCode;name;description;numId;manufacturer;status;procedure;form;atcCode;activeIngredient;
library;

import 'package:http/http.dart' as http;

// ── Data classes ─────────────────────────────────────────────

/// A single search result from the AIFA database.
class AifaSearchResult {
  const AifaSearchResult({
    required this.code,
    required this.groupCode,
    required this.name,
    required this.description,
    this.manufacturer,
    this.activeIngredient,
    this.form,
    this.atcCode,
    this.status,
  });

  final String code;
  final String groupCode;
  final String name;
  final String description;
  final String? manufacturer;
  final String? activeIngredient;
  final String? form;
  final String? atcCode;
  final String? status;

  /// Display-friendly subtitle.
  String get subtitle => [
        if (activeIngredient != null && activeIngredient!.isNotEmpty)
          activeIngredient,
        if (manufacturer != null && manufacturer!.isNotEmpty) manufacturer,
        if (form != null && form!.isNotEmpty) form,
      ].join(' · ');

  bool get hasData => name.isNotEmpty;
}

// ── Datasource ───────────────────────────────────────────────

class BarcodeLookupDatasource {
  BarcodeLookupDatasource({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const _aifaUrl = 'https://drive.aifa.gov.it/farmaci/confezioni.csv';

  /// Strip leading non-digit characters from a scanned text.
  /// e.g. "A023834118" → "023834118"
  static String cleanCode(String raw) {
    return raw.replaceAll(RegExp(r'^[^0-9]+'), '');
  }

  /// Regex to detect AIC-like codes in scanned text.
  /// Matches: optional leading letter + 6-9 digits (e.g. A023834118).
  static final _aicPattern = RegExp(r'[A-Za-z]?\d{6,9}');

  /// Extract possible AIC codes from OCR text.
  static List<String> extractCodes(String ocrText) {
    final matches = _aicPattern.allMatches(ocrText);
    return matches
        .map((m) => cleanCode(m.group(0)!))
        .where((c) => c.length >= 6)
        .toSet()
        .toList();
  }

  /// Search the AIFA CSV for a given AIC code.
  /// Searches by full code (9 digits) or group code (first 6 digits).
  Future<List<AifaSearchResult>> search(String code) async {
    final cleanedCode = cleanCode(code);
    if (cleanedCode.length < 6) return [];

    final response = await _client
        .get(Uri.parse(_aifaUrl), headers: {'User-Agent': 'Medora/1.0'})
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) return [];

    return _parseCsv(response.body, cleanedCode);
  }

  /// Parse the AIFA CSV and filter by code.
  List<AifaSearchResult> _parseCsv(String csvBody, String searchCode) {
    final results = <AifaSearchResult>[];
    final lines = csvBody.split('\n');

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final fields = line.split(';');
      if (fields.length < 12) continue;

      final fullCode = fields[0].trim();
      final groupCode = fields[1].trim();

      // Match: exact full code, or group code prefix
      final matches = fullCode == searchCode ||
          groupCode == searchCode ||
          fullCode.startsWith(searchCode) ||
          searchCode.startsWith(groupCode);

      if (!matches) continue;

      results.add(AifaSearchResult(
        code: fullCode,
        groupCode: groupCode,
        name: _titleCase(fields[3].trim()),
        description: fields[4].trim(),
        manufacturer: fields[6].trim().isNotEmpty ? fields[6].trim() : null,
        status: fields[7].trim().isNotEmpty ? fields[7].trim() : null,
        form: fields[9].trim().isNotEmpty ? fields[9].trim() : null,
        atcCode: fields[10].trim().isNotEmpty ? fields[10].trim() : null,
        activeIngredient:
            fields[11].trim().isNotEmpty ? _titleCase(fields[11].trim()) : null,
      ));
    }

    // Sort: exact match first, then by name
    results.sort((a, b) {
      if (a.code == searchCode && b.code != searchCode) return -1;
      if (b.code == searchCode && a.code != searchCode) return 1;
      return a.name.compareTo(b.name);
    });

    return results;
  }

  /// Convert UPPER CASE to Title Case.
  static String _titleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((w) => w.isNotEmpty
            ? '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'
            : '')
        .join(' ');
  }
}
