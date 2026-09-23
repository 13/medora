/// Medora - Rules of an Italian prescription: how long it is valid, when a
/// referral should be booked, and what state it is in.
///
/// The numbers live here and nowhere else. Sources (checked 2026-09-23):
/// - SSN validity, 30 days excluding the issue day: D.P.R. 8 luglio 1998,
///   n. 371, art. 4 ("la validita' della ricetta e' di 30 giorni, escluso
///   quello di emissione") -
///   https://www.gazzettaufficiale.it/atto/serie_generale/caricaArticolo?art.progressivo=0&art.idArticolo=4&art.versione=1&art.codiceRedazionale=098G0422&art.dataPubblicazioneGazzetta=1998-10-27&art.idGruppo=0&art.idSottoArticolo1=10&art.idSottoArticolo=1&art.flagTipoArticolo=1
/// - white (non-repeatable, non-SSN) prescriptions, 30 days nationwide:
///   R.D. 27 luglio 1934, n. 1265, art. 88, as commonly summarised by
///   pharmacist-facing sources (no single official full-text page located
///   within the search budget; corroborated by
///   https://www.fcr.re.it/medicinali-soggetti-a-prescrizione-medica-non-ripetibile
///   and https://it.wikipedia.org/wiki/Ricetta_del_Servizio_sanitario_nazionale_italiano).
/// - repeatable white prescriptions, 6 months / max 10 dispensings: same
///   art. 88, as amended; consensus of multiple pharmacist sources -
///   https://www.medicinapertutti.it/argomento/ricetta-ripetibile/ ,
///   https://farmaciapontevecchio.it/ricette-ripetibili-mutuabili/ . Note:
///   the Italian Wikipedia page above instead gives 3 months / 5 packages
///   for a *private* repeatable prescription; the plan's 6-months/10 value
///   is kept because it is the value repeated across the majority of
///   pharmacist-facing sources checked, but flag as not settled by a single
///   authoritative legal citation.
/// - priority classes U/B/D/P (72h / 10 / 30 / 120 days), from the national
///   waiting-list plan, reproduced on ASL/ASU institutional pages -
///   https://asugi.sanita.fvg.it/it/schede/s_dir_san/cup_tmp_criteri_priorita-codici_ubdp.html
library;

enum RxKind {
  ssn('ssn'),
  white('white'),
  whiteRepeatable('white_repeatable'),
  referral('referral');

  const RxKind(this.wire);
  final String wire;

  static RxKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => RxKind.ssn);
}

enum RxPriority {
  u('U', 3),
  b('B', 10),
  d('D', 30),
  p('P', 120);

  const RxPriority(this.wire, this.bookWithinDays);
  final String wire;

  /// Days from issue within which the visit should take place.
  final int bookWithinDays;

  static RxPriority? fromWire(String? raw) {
    for (final p in values) {
      if (p.wire == raw) return p;
    }
    return null;
  }
}

abstract final class RxValidity {
  static const _days = {RxKind.ssn: 30, RxKind.white: 30};
  static const _repeatableMonths = 6;
  static const _repeatableDispensings = 10;

  /// The last valid day of a prescription issued on [issuedOn], or null when
  /// the kind has no fixed validity (a referral: the user enters it).
  ///
  /// The issue day does not count, so 30 days from 23 September is
  /// 23 October.
  static DateTime? defaultValidUntil(RxKind kind, DateTime issuedOn) {
    final day = DateTime(issuedOn.year, issuedOn.month, issuedOn.day);
    final days = _days[kind];
    if (days != null) return DateTime(day.year, day.month, day.day + days);
    if (kind == RxKind.whiteRepeatable) {
      return _addMonths(day, _repeatableMonths);
    }
    return null;
  }

  static int? defaultMaxDispensings(RxKind kind) =>
      kind == RxKind.whiteRepeatable ? _repeatableDispensings : null;

  static DateTime bookBy(RxPriority priority, DateTime issuedOn) => DateTime(
    issuedOn.year,
    issuedOn.month,
    issuedOn.day + priority.bookWithinDays,
  );

  /// [months] later, on the same day or the month's last day when that
  /// month is shorter (31 August + 6 months = 28 February).
  static DateTime _addMonths(DateTime day, int months) {
    final firstOfTarget = DateTime(day.year, day.month + months);
    final lastDay = DateTime(
      firstOfTarget.year,
      firstOfTarget.month + 1,
      0,
    ).day;
    return DateTime(
      firstOfTarget.year,
      firstOfTarget.month,
      day.day > lastDay ? lastDay : day.day,
    );
  }
}
