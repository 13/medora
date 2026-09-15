/// Medora - where a scanned food-supplement code leads
///
/// Pure decision used by the scanner after a register lookup, kept out of the
/// screen (camera and ML Kit plugins cannot be pumped in widget tests).
library;

import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// What the scanner does with the register matches for a supplement code.
sealed class SupplementRoute {
  const SupplementRoute();
}

/// Exactly one product: open Add Medication prefilled with it.
final class SupplementPrefill extends SupplementRoute {
  const SupplementPrefill(this.entry);
  final SupplementEntry entry;
}

/// Several products share the code: let the user pick one.
final class SupplementPick extends SupplementRoute {
  const SupplementPick(this.entries);
  final List<SupplementEntry> entries;
}

/// Not in the register: say so and open Add Medication with the code.
final class SupplementNotFound extends SupplementRoute {
  const SupplementNotFound();
}

SupplementRoute supplementRouteFor(List<SupplementEntry> matches) =>
    switch (matches) {
      [] => const SupplementNotFound(),
      [final only] => SupplementPrefill(only),
      _ => SupplementPick(matches),
    };

/// The [lookup] matches for a scanned [code]: when [code] has none, each of
/// its [alternatives] (other OCR readings, see `CodeCandidate.alternatives`)
/// in order. Returns the first code with matches, else [code] with no
/// matches. A returned code other than [code] was not read as such: confirm
/// it with the user before using it (`confirmAlternativeCode`).
Future<({String code, List<T> matches})> findByCodes<T>(
  Future<List<T>> Function(String code) lookup,
  String code, [
  List<String> alternatives = const [],
]) async {
  for (final candidate in [code, ...alternatives]) {
    final matches = await lookup(candidate);
    if (matches.isNotEmpty) return (code: candidate, matches: matches);
  }
  return (code: code, matches: <T>[]);
}

/// [findByCodes] in the food-supplement register.
Future<({String code, List<SupplementEntry> matches})> findSupplementByCodes(
  SupplementRegistryService service,
  String code, [
  List<String> alternatives = const [],
]) => findByCodes(service.findByCode, code, alternatives);

/// Add Medication with [code] in the barcode field.
String addMedicationWithBarcode(String code) =>
    '${AppRoutes.addMedication}?barcode=${Uri.encodeQueryComponent(code)}';
