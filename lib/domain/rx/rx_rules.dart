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
///   pharmacist-facing sources checked. Confirmed 2026-09-24 against a real
///   2026 white repeatable prescription the user photographed (not
///   reproduced here, per the privacy rule): it prints "RIPETIBILE PER 10
///   VOLTE E VALIDA FINO AL" with a valid-until date six months after
///   issue, closing the citation gap above (design doc §11).
/// - priority classes U/B/D/P (72h / 10 / 30 / 120 days): Piano Nazionale di
///   Governo delle Liste d'Attesa (PNGLA) 2019-2021, Intesa Stato-Regioni
///   21 febbraio 2019 - these are the national deadlines by which the
///   service must be *delivered* ("da eseguirsi entro"), not a booking
///   deadline (D is 30 days for visits, 60 for instrumental exams; the app
///   uses the visit value) -
///   https://www.salute.gov.it/new/it/pubblicazione/piano-nazionale-di-governo-delle-liste-di-attesa-il-triennio-2019-2021/ ;
///   the exact wording ("prestazioni da eseguirsi entro ...") is quoted at
///   https://leparoledellasalute.federsanitatoscana.it/classe-di-priorita/ .
///   The PDF of the plan itself is blocked to automated fetches by
///   salute.gov.it's bot protection, so it could not be quoted directly;
///   the Ministry publication page above and the independent secondary
///   source were both confirmed reachable.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';

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

  const RxPriority(this.wire, this.visitWithinDays);
  final String wire;

  /// Days from issue within which the visit should take place.
  final int visitWithinDays;

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

  /// The date by which the visit should take place (national priority
  /// class deadline); D is 30 days for visits, 60 for instrumental exams —
  /// the app uses the visit value.
  static DateTime visitBy(RxPriority priority, DateTime issuedOn) => DateTime(
    issuedOn.year,
    issuedOn.month,
    issuedOn.day + priority.visitWithinDays,
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

enum RxStatus { open, partial, redeemed, expired, cancelled }

abstract final class RxRules {
  /// Packs collected per item id.
  static Map<String, int> dispensedPacks(List<RxDispensing> dispensings) {
    final sums = <String, int>{};
    for (final d in dispensings) {
      sums[d.itemId] = (sums[d.itemId] ?? 0) + d.packs;
    }
    return sums;
  }

  /// The state of [rx] at [now], given its [dispensings]. Never stored:
  /// "expired" changes with the date alone.
  ///
  /// Order matters: a cancelled prescription is cancelled whatever was
  /// collected, and one fully collected is redeemed even after its last
  /// valid day.
  static RxStatus statusOf(
    Rx rx,
    List<RxDispensing> dispensings,
    DateTime now,
  ) {
    if (rx.cancelled) return RxStatus.cancelled;
    if (rx.closedOn != null || _fullyDispensed(rx, dispensings)) {
      return RxStatus.redeemed;
    }
    final left = daysLeft(rx, now);
    if (left != null && left < 0) return RxStatus.expired;
    return dispensings.isEmpty ? RxStatus.open : RxStatus.partial;
  }

  /// A repeatable prescription is used up after [Rx.maxDispensings]
  /// pharmacy visits, not rows: the rule limits how often it is presented,
  /// and one visit that collects two items is still one use. A visit is a
  /// distinct `dispensedOn` date.
  static bool _fullyDispensed(Rx rx, List<RxDispensing> dispensings) {
    final max = rx.maxDispensings;
    if (max != null) return visits(dispensings) >= max;
    if (rx.items.isEmpty) return false;
    final given = dispensedPacks(dispensings);
    return rx.items.every((i) => (given[i.id] ?? 0) >= i.packs);
  }

  /// Pharmacy visits among [dispensings]: the distinct days they were
  /// collected on.
  static int visits(List<RxDispensing> dispensings) => {
    for (final d in dispensings)
      DateTime(d.dispensedOn.year, d.dispensedOn.month, d.dispensedOn.day),
  }.length;

  /// Calendar days from [now] to the last valid day: 0 on that day,
  /// negative once it has passed, null when no validity is known.
  static int? daysLeft(Rx rx, DateTime now) {
    final until = rx.validUntil;
    return until == null ? null : calendarDaysBetween(now, until);
  }

  /// Units in one pack, read from a pack description ("20 compresse",
  /// "30 cpr", "20 Tabletten"); null for volumes or when none is named.
  static int? packSizeOf(String description) {
    final match = _packCount.firstMatch(description.toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static final _packCount = RegExp(
    r'(\d+)\s*(?:compresse|compressa|cpr|cp|capsule|caps|cps|bustine|'
    r'tabletten|tabl|kapseln|stück|stk|tablets|capsules|pz|pezzi)\b',
  );
}
