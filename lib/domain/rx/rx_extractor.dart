/// Medora - Reads a prescription draft from a scan.
///
/// Input is what the camera recognised: the decoded barcodes and the text
/// lines (ML Kit order, which is not always reading order). Barcodes are
/// trusted; text is only suggested (see [RxDraft.fromBarcode]). The NRE is
/// never read from text: a misread digit would send the user to the
/// pharmacy with a wrong number.
///
/// Calibrated on the two South Tyrol layouts (spec §11): the SSN promemoria
/// and the white electronic promemoria, both bilingual German/Italian.
library;

import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/domain/rx/tax_code.dart';

abstract final class RxExtractor {
  /// [barcodes]: decoded values in the order found; [text]: all recognised
  /// text, lines joined with '\n' in reading order (order may be imperfect);
  /// [knownTaxCodes]: tax codes of persons on this device (a match is the
  /// patient).
  static RxDraft extract({
    required List<String> barcodes,
    required String text,
    Set<String> knownTaxCodes = const {},
  }) {
    final lines = [
      for (final l in text.split('\n'))
        l
            .replaceAll(RegExp(r'[’‘`´]'), "'")
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
    ];
    final upperLines = [for (final l in lines) l.toUpperCase()];
    final upper = upperLines.join('\n');
    final fromBarcode = <String>{};

    // 1. Barcodes. A field with more than one distinct candidate (two
    // sheets in one photo, a misread) is left empty rather than guessed.
    final part1s = <String>{};
    final part2s = <String>{};
    final nrbes = <String>{};
    final pins = <String>{};
    final barcodeTaxCodes = <String>[];
    for (final raw in barcodes) {
      final code = raw.replaceAll(RegExp(r'[\s*]'), '').toUpperCase();
      if (TaxCode.isValid(code)) {
        if (!barcodeTaxCodes.contains(code)) barcodeTaxCodes.add(code);
      } else if (_nrePart1.hasMatch(code)) {
        // Never a PIN: an NRE first half is the likelier reading.
        part1s.add(code);
      } else if (_nrePart2.hasMatch(code)) {
        part2s.add(code);
      } else if (Nre.isNrbe(code)) {
        nrbes.add(code);
      } else if (Nre.isPin(code)) {
        pins.add(code);
      }
    }
    String? single(Set<String> values) =>
        values.length == 1 ? values.single : null;
    final part1 = single(part1s);
    final part2 = single(part2s);
    final nrbe = single(nrbes);
    String? nre;
    String? pin;
    if (part1 != null && part2 != null && Nre.isValid(part1 + part2)) {
      nre = part1 + part2;
    } else if (nrbe != null) {
      nre = nrbe;
      pin = single(pins);
    }
    if (nre != null) fromBarcode.add('nre');
    if (pin != null) fromBarcode.add('pin');

    // 2. Patient vs doctor tax code.
    final candidates = <String>[...barcodeTaxCodes];
    for (final m in _taxCodeInText.allMatches(upper)) {
      final code = m[0]!;
      if (TaxCode.isValid(code) && !candidates.contains(code)) {
        candidates.add(code);
      }
    }
    // A role is confident when it comes from a person on this device or
    // from a label that names exactly one code for it. Otherwise the order
    // (barcodes first, then text) decides: the first is the patient, the
    // next the doctor. Such a guess is never marked as barcode-trusted.
    // A doctor code is only set when another code is the patient.
    final known = {for (final k in knownTaxCodes) TaxCode.normalize(k)};
    final roles = {for (final c in candidates) c: _roleNear(upper, c)};
    String? only(Iterable<String> codes) =>
        codes.length == 1 ? codes.single : null;
    var patientCode =
        candidates.where(known.contains).firstOrNull ??
        only(candidates.where((c) => roles[c] == _Role.patient));
    final patientSure = patientCode != null;
    final others = [
      for (final c in candidates)
        if (c != patientCode && !known.contains(c)) c,
    ];
    var doctorCode = only(others.where((c) => roles[c] == _Role.doctor));
    final doctorSure = doctorCode != null;
    patientCode ??= others.where((c) => c != doctorCode).firstOrNull;
    doctorCode ??= others.where((c) => c != patientCode).firstOrNull;
    if (patientCode == null) doctorCode = null;
    if (patientSure && barcodeTaxCodes.contains(patientCode)) {
      fromBarcode.add('taxCode');
    }
    if (doctorSure &&
        doctorCode != null &&
        barcodeTaxCodes.contains(doctorCode)) {
      fromBarcode.add('doctorTaxCode');
    }

    // 3. Kind.
    RxKind? kind;
    // A valid NRE pair is SSN whatever the text says (NRBE is another
    // format).
    final ssnPair = nre != null && nre != nrbe;
    if (!ssnPair &&
        (upper.contains('RICETTA BIANCA') || (nre != null && nre == nrbe))) {
      kind = upper.contains('RIPETIBILE') && _volte.hasMatch(upper)
          ? RxKind.whiteRepeatable
          : RxKind.white;
    } else if (nre != null ||
        upper.contains('ASSIST.SSN') ||
        upper.contains("PROMEMORIA PER L'ASSISTITO")) {
      kind = RxKind.ssn;
    }

    // 4. Dates.
    final validityMatches = _validUntil.allMatches(upper).toList();
    final validityDateStarts = {
      for (final m in validityMatches) m.end - _dateLength(m),
    };
    final issuedOn = _issuedOn(upperLines, validityDateStarts, [
      for (final m in validityMatches) ?_date(m),
    ]);
    DateTime? validUntil;
    int? validDays;
    if (validityMatches.isNotEmpty) {
      validUntil = _date(validityMatches.first);
    } else {
      final days = _validForDays.firstMatch(upper);
      if (days != null && issuedOn != null) {
        validDays = int.parse(days[1]!);
        validUntil = DateTime(
          issuedOn.year,
          issuedOn.month,
          issuedOn.day + validDays,
        );
      }
    }

    // 5. Repeat count.
    final repeats = _repeats.firstMatch(upper);
    final maxDispensings = repeats == null ? null : int.parse(repeats[1]!);

    // 6. Exemption.
    String? exemptionCode;
    for (final m in _exemption.allMatches(upper)) {
      final value = m[1]!;
      if (value.startsWith('NON') || !value.contains(RegExp('[0-9]'))) {
        continue;
      }
      exemptionCode = value;
      break;
    }

    // 7. Priority.
    final priorityMatch = _priority.firstMatch(upper);
    final priority = RxPriority.fromWire(priorityMatch?[1]);

    // 8. Names (first line only).
    String? patientName;
    String? doctor;
    for (var i = 0; i < upperLines.length; i++) {
      patientName ??= _name(_patientName.firstMatch(upperLines[i]));
      if (doctor != null) continue;
      final m = _doctorName.firstMatch(upperLines[i]);
      doctor = _name(m);
      // The printout may wrap the first name onto the next line.
      if (doctor != null &&
          i + 1 < upperLines.length &&
          _nameContinuation.hasMatch(upperLines[i + 1])) {
        doctor = _titleCase('${m![1]!.trim()} ${upperLines[i + 1]}');
      }
    }

    // 9. Items.
    final items = _items(lines, hasQtyColumn: upper.contains('MENGE QTA'));

    return RxDraft(
      kind: kind,
      nre: nre,
      pin: pin,
      taxCode: patientCode,
      patientName: patientName,
      doctor: doctor,
      doctorTaxCode: doctorCode,
      issuedOn: issuedOn,
      validUntil: validUntil,
      validDays: validDays,
      maxDispensings: maxDispensings,
      exemptionCode: exemptionCode,
      priority: priority,
      items: items,
      fromBarcode: fromBarcode,
    );
  }

  static final _nrePart1 = RegExp(r'^[0-9]{3}[A-Z][0-9]$');
  static final _nrePart2 = RegExp(r'^[0-9]{10}$');
  static final _taxCodeInText = RegExp(
    r'(?<![A-Z0-9])[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z]'
    r'[0-9LMNPQRSTUV]{3}[A-Z](?![A-Z0-9])',
  );
  static final _label = RegExp(
    r'(?<![A-Z])(?:(ASSISTITO|PAZIENTE|BETREUTEN|PATIENTEN)|'
    r'(MEDICO|ARZTES|ARZT|MED\.))(?![A-Z])',
  );
  static final _volte = RegExp(r'(?<![A-Z])VOLTE(?![A-Z])');
  static const _dmy = r'([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})';
  static final _anyDate = RegExp('(?<![0-9])$_dmy(?![0-9])');
  static final _issuedLabel = RegExp(
    'DATUM/DATA|AUSSTELLUNGSDATUM|DATA COMPILAZIONE',
  );
  static final _issuedStrict = RegExp(
    '(?:DATUM/DATA|AUSSTELLUNGSDATUM|DATA COMPILAZIONE)[^0-9]{0,40}$_dmy',
  );
  static final _validUntil = RegExp(
    '(?:GÜLTIG BIS ZUM|GULTIG BIS ZUM|VALIDA FINO AL)[^0-9]{0,40}$_dmy',
  );
  static final _validForDays = RegExp(
    r'(?:VALIDA PER|GÜLTIG FÜR|GULTIG FUR)\s+([0-9]{1,3})\s+(?:GIORNI|TAGE)',
  );
  static final _repeats = RegExp(
    r'(?<![A-Z])(?:PER|FÜR|FUR)\s+([0-9]{1,2})\s+VOLTE',
  );
  static final _exemption = RegExp(
    r'ESENZIONE *: *([A-Z0-9]{2,6})(?![A-Z0-9])',
  );
  static final _priority = RegExp(
    r"PRIORIT[AÀ]'? *PRESCRIZIONE *\(U,B,D,P\) *: *([UBDP])(?![A-Z0-9])",
  );
  static const _patientLabels =
      "ZUNAME UND NAME DES BETREUTEN|COGNOME E NOME DELL'ASSISTITO|"
      'COGNOME E NOME DEL PAZIENTE|NACHNAME UND NAME DES PATIENTEN';
  static final _patientNameLabel = RegExp(_patientLabels);
  static final _patientName = RegExp(
    '(?:$_patientLabels)'
    r"[^:]*: *([A-ZÀ-Ü' ]{3,}?)(?= {2,}| [0-9]|$)",
  );
  static final _doctorName = RegExp(
    r'(?:ZUNAME UND NAME DES ARZTES|COGNOME E NOME DEL MEDICO)[^:]*: *'
    r"([A-ZÀ-Ü' ]{3,})",
  );
  static final _nameContinuation = RegExp(r"^[A-ZÀ-Ü']+(?: [A-ZÀ-Ü']+){0,2}$");

  /// Items: a 9-digit AIC (one OCR space and `O` for `0` allowed) not
  /// touching other digits, then the product name.
  static final _aic = RegExp(
    r'(?<![0-9A-Z])\(?([0-9O]{8} ?[0-9O])(?![0-9])\)?',
    caseSensitive: false,
  );
  static final _qty = RegExp(
    r' *QTA ?/ ?MENGE *: *([0-9]+) *$',
    caseSensitive: false,
  );
  static final _trailingCount = RegExp(r' ([1-9])$');
  static final _confezioni = RegExp(
    r'N\.? *CONFEZIONI/PRESTAZIONI *: *([0-9]+)',
    caseSensitive: false,
  );
  static final _posologyLabel = RegExp(
    r'POSOLOGIA(?:/POSOLOGIE)? *: *(.*)$',
    caseSensitive: false,
  );
  static final _posologyTail = RegExp(r' *TDL *:.*$', caseSensitive: false);
  static final _ssnPosologyLine = RegExp(
    r'^(?:\(EGA\)|USO(?![A-Z]))',
    caseSensitive: false,
  );

  /// The nearest label before the first occurrence of [code] (within 250
  /// characters) says whose code it is.
  static _Role? _roleNear(String upper, String code) {
    final at = upper.indexOf(code);
    if (at < 0) return null;
    final window = upper.substring(at < 250 ? 0 : at - 250, at);
    final last = _label.allMatches(window).lastOrNull;
    if (last == null) return null;
    return last[1] != null ? _Role.patient : _Role.doctor;
  }

  /// The labelled issue date; when OCR put the date on another line, the
  /// date nearest to the label (before or after, within 100 characters).
  /// Never a validity date, a date on the patient's name line (the birth
  /// date) or that birth date elsewhere, a date before 2000 or one after a
  /// stated validity date: no issue date beats a wrong one.
  static DateTime? _issuedOn(
    List<String> upperLines,
    Set<int> validityDateStarts,
    List<DateTime> validityDates,
  ) {
    final upper = upperLines.join('\n');
    final patientLineRanges = <(int, int)>[];
    var offset = 0;
    for (final line in upperLines) {
      if (_patientNameLabel.hasMatch(line)) {
        patientLineRanges.add((offset, offset + line.length));
      }
      offset += line.length + 1;
    }
    bool onPatientLine(int at) =>
        patientLineRanges.any((r) => at >= r.$1 && at <= r.$2);
    final birthDates = {
      for (final d in _anyDate.allMatches(upper))
        if (onPatientLine(d.start)) ?_date(d),
    };
    DateTime? plausible(RegExpMatch m) {
      final start = m.end - _dateLength(m);
      if (validityDateStarts.contains(start) || onPatientLine(start)) {
        return null;
      }
      final d = _date(m);
      if (d == null || d.year < 2000 || birthDates.contains(d)) return null;
      if (validityDates.any(d.isAfter)) return null;
      return d;
    }

    for (final m in _issuedStrict.allMatches(upper)) {
      final d = plausible(m);
      if (d != null) return d;
    }
    final dates = [
      for (final d in _anyDate.allMatches(upper))
        if (plausible(d) != null) d,
    ];
    for (final label in _issuedLabel.allMatches(upper)) {
      RegExpMatch? best;
      var bestDistance = 101;
      for (final d in dates) {
        final distance = d.start >= label.end
            ? d.start - label.end
            : label.start - d.end;
        if (distance >= 0 && distance < bestDistance) {
          best = d;
          bestDistance = distance;
        }
      }
      if (best != null) return _date(best);
    }
    return null;
  }

  /// Length of the dd/mm/yyyy text at the end of [m].
  static int _dateLength(RegExpMatch m) {
    final n = m.groupCount;
    return m[n - 2]!.length + m[n - 1]!.length + m[n]!.length + 2;
  }

  /// A dd/mm/yyyy match (groups 1-3 from the end); null for an impossible
  /// date such as 31/02.
  static DateTime? _date(RegExpMatch m) {
    final n = m.groupCount;
    final day = int.parse(m[n - 2]!);
    final month = int.parse(m[n - 1]!);
    final year = int.parse(m[n]!);
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  static String? _name(RegExpMatch? m) {
    final raw = m?[1]?.trim();
    if (raw == null || raw.replaceAll(RegExp("[ ']"), '').length < 2) {
      return null;
    }
    return _titleCase(raw);
  }

  /// "D'ANGELO ANNA" -> "D'Angelo Anna".
  static String _titleCase(String upper) {
    final out = StringBuffer();
    var startOfWord = true;
    for (final ch in upper.toLowerCase().split('')) {
      out.write(startOfWord ? ch.toUpperCase() : ch);
      startOfWord = ch == ' ' || ch == "'" || ch == '-';
    }
    return out.toString().replaceAll(RegExp(' +'), ' ');
  }

  static List<RxDraftItem> _items(
    List<String> lines, {
    required bool hasQtyColumn,
  }) {
    final found = <_ItemLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final m = _aic.firstMatch(line);
      if (m == null) continue;
      final run = m[1]!;
      if (RegExp('[Oo]').allMatches(run).length > 2) continue;
      var rest = line.substring(m.end).replaceFirst(RegExp(r'^[ )\-–]+'), '');
      if (!RegExp(r'^[A-Za-zÀ-ÿ]').hasMatch(rest)) continue;
      int? packs;
      final qty = _qty.firstMatch(rest);
      if (qty != null) {
        packs = int.parse(qty[1]!);
        rest = rest.substring(0, qty.start);
      } else {
        // Only the SSN form has a quantity column ("MENGE QTA"); elsewhere
        // a trailing number is part of the name (EUTIROX 50).
        final count = hasQtyColumn ? _trailingCount.firstMatch(rest) : null;
        if (count != null) {
          packs = int.parse(count[1]!);
          rest = rest.substring(0, count.start);
        } else if (i + 1 < lines.length &&
            _aic.firstMatch(lines[i + 1]) == null) {
          final next = RegExp(
            r'QTA ?/ ?MENGE *: *([0-9]+)',
            caseSensitive: false,
          ).firstMatch(lines[i + 1]);
          if (next != null) packs = int.parse(next[1]!);
        }
      }
      rest = rest.trim();
      if (rest.length < 3) continue;
      found.add(
        _ItemLine(
          line: i,
          aic: run.replaceAll(' ', '').replaceAll(RegExp('[Oo]'), '0'),
          description: rest,
          packs: packs,
        ),
      );
    }
    if (found.isEmpty) return const [];

    // Packs: the total on the SSN form, when there is only one item.
    if (found.length == 1 && found.single.packs == null) {
      final totals = {
        for (final l in lines)
          for (final m in _confezioni.allMatches(l)) int.parse(m[1]!),
      };
      if (totals.length == 1) found.single.packs = totals.single;
    }

    // Posology, white layout: each label (even an empty one) belongs to
    // the nearest item above it that has none yet; failing that (lines
    // out of order), to the nearest such item below it.
    final labelled = <_ItemLine>{};
    for (var i = 0; i < lines.length; i++) {
      final m = _posologyLabel.firstMatch(lines[i]);
      if (m == null) continue;
      final free = [
        for (final f in found)
          if (!labelled.contains(f)) f,
      ];
      final item =
          free.where((f) => f.line < i).lastOrNull ??
          free.where((f) => f.line > i).firstOrNull;
      if (item == null) continue;
      labelled.add(item);
      final value = m[1]!.replaceFirst(_posologyTail, '').trim();
      if (value.isNotEmpty) item.posology = value;
    }

    // Posology, SSN layout: the tail of the "(EGA) …" / "USO …" line
    // directly under the item. When lines are out of order (such a line
    // comes before the first item), none is guessed, unless there is just
    // one item and one such line.
    String? ssnPosology(int i) {
      final l = lines[i];
      if (!_ssnPosologyLine.hasMatch(l)) return null;
      final dash = l.lastIndexOf(' - ');
      if (dash < 0) return null;
      final tail = l.substring(dash + 3).trim();
      return tail.isEmpty ? null : tail;
    }

    final ssnLines = [
      for (var i = 0; i < lines.length; i++)
        if (ssnPosology(i) != null) i,
    ];
    final open = [
      for (final f in found)
        if (!labelled.contains(f)) f,
    ];
    if (found.length == 1 && ssnLines.length == 1 && open.length == 1) {
      open.single.posology = ssnPosology(ssnLines.single);
    } else if (ssnLines.isNotEmpty && ssnLines.first > found.first.line) {
      for (final item in open) {
        if (ssnLines.contains(item.line + 1)) {
          item.posology = ssnPosology(item.line + 1);
        }
      }
    }

    return [
      for (final f in found)
        RxDraftItem(
          aic: f.aic,
          description: f.description,
          packs: f.packs ?? 1,
          posology: f.posology,
        ),
    ];
  }
}

enum _Role { patient, doctor }

class _ItemLine {
  _ItemLine({
    required this.line,
    required this.aic,
    required this.description,
    this.packs,
  });

  final int line;
  final String aic;
  final String description;
  int? packs;
  String? posology;
}
