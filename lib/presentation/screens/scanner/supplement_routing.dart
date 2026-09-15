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

/// The register matches for a scanned supplement [code]: when [code] has
/// none, each of its [alternatives] (other OCR readings, see
/// `CodeCandidate.alternatives`) in order. Returns the first code with
/// matches, else [code] with no matches.
Future<({String code, List<SupplementEntry> matches})> findSupplementByCodes(
  SupplementRegistryService service,
  String code, [
  List<String> alternatives = const [],
]) async {
  for (final candidate in [code, ...alternatives]) {
    final matches = await service.findByCode(candidate);
    if (matches.isNotEmpty) return (code: candidate, matches: matches);
  }
  return (code: code, matches: const <SupplementEntry>[]);
}

/// Add Medication with [code] in the barcode field.
String addMedicationWithBarcode(String code) =>
    '${AppRoutes.addMedication}?barcode=${Uri.encodeQueryComponent(code)}';
