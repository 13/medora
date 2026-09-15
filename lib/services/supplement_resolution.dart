/// Medora - resolving a scanned supplement code against the cached register
///
/// OCR may read `T07018` where the pack prints `107018`. The candidate keeps
/// the alternative readings; when the register is already on the device we
/// can settle which one is real *before* the review list renders, so the
/// chip shows the code the lookup will use and the user is not asked to
/// confirm a code they never saw. Without a cached register the scanner
/// falls back to asking at selection time (`confirmAlternativeCode`).
library;

import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// See the library doc. Non-supplement candidates, candidates that match as
/// read and candidates that match nothing come back as the same instances.
Future<List<CodeCandidate>> resolveSupplementCandidates(
  List<CodeCandidate> candidates,
  Future<List<SupplementEntry>> Function(String code) findByCode,
) async {
  final resolved = <CodeCandidate>[];
  final codes = <String>{
    for (final c in candidates)
      if (c.kind == CodeKind.supplement) c.code,
  };
  for (final candidate in candidates) {
    if (candidate.kind != CodeKind.supplement) {
      resolved.add(candidate);
      continue;
    }
    String? match;
    for (final code in [candidate.code, ...candidate.alternatives]) {
      if ((await findByCode(code)).isNotEmpty) {
        match = code;
        break;
      }
    }
    if (match == null || match == candidate.code) {
      resolved.add(candidate);
      continue;
    }
    if (!codes.add(match)) continue; // already on the list as read
    resolved.add(
      CodeCandidate(
        code: match,
        kind: candidate.kind,
        sourceText: candidate.sourceText,
        box: candidate.box,
      ),
    );
  }
  return resolved;
}
