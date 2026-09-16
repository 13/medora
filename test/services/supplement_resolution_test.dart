import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:medora/services/supplement_resolution.dart';

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);

CodeCandidate _supplement(
  String code, {
  List<String> alternatives = const [],
  Rect box = const Rect.fromLTWH(0, 0, 100, 20),
}) => CodeCandidate(
  code: code,
  kind: CodeKind.supplement,
  sourceText: 'COD MINSAN: $code',
  box: box,
  alternatives: alternatives,
);

/// Built from a parameter on purpose: a non-const instance, so
/// `identical` really pins the instance and not a canonicalised twin.
CodeCandidate _aic(String code, {List<String> alternatives = const []}) =>
    CodeCandidate(
      code: code,
      kind: CodeKind.aic,
      sourceText: 'AIC $code',
      box: const Rect.fromLTWH(0, 0, 10, 10),
      alternatives: alternatives,
    );

void main() {
  final asked = <String>[];
  Future<List<SupplementEntry>> find(String code) async {
    asked.add(code);
    return SupplementRegistryService.codeKey(code) ==
            SupplementRegistryService.codeKey('107018')
        ? [_zinco]
        : const [];
  }

  setUp(asked.clear);

  test('an alternative that matches becomes the candidate code', () async {
    final result = await resolveSupplementCandidates([
      _supplement('707018', alternatives: ['107018']),
    ], find);
    expect(result.single.code, '107018');
    expect(result.single.alternatives, isEmpty);
    expect(result.single.kind, CodeKind.supplement);
    expect(result.single.sourceText, 'COD MINSAN: 707018');
    expect(result.single.box, const Rect.fromLTWH(0, 0, 100, 20));
    expect(asked, ['707018', '107018']);
  });

  test('a code that matches as read is untouched', () async {
    final input = [
      _supplement('107018', alternatives: ['707018']),
    ];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(asked, ['107018']);
  });

  test('no match anywhere leaves the candidate and its alternatives', () async {
    final input = [
      _supplement('999999', alternatives: ['888888']),
    ];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(result.single.alternatives, ['888888']);
    expect(asked, ['999999', '888888']);
  });

  test('other kinds are never looked up', () async {
    final input = [
      _aic('034567891', alternatives: const ['134567891']),
    ];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(asked, isEmpty);
  });

  test('a code is looked up once for the whole list', () async {
    // Review M1: every lookup is a database round trip on the UI isolate.
    final result = await resolveSupplementCandidates([
      _supplement('999999', alternatives: ['888888']),
      _supplement('888888', alternatives: ['107018']),
    ], find);
    expect(asked, ['999999', '888888', '107018']);
    expect(result.map((c) => c.code), ['999999', '107018']);
  });

  test('a rewrite that collides with an existing chip is dropped', () async {
    final result = await resolveSupplementCandidates([
      _supplement('107018'),
      _supplement(
        '707018',
        alternatives: ['107018'],
        box: const Rect.fromLTWH(0, 40, 100, 20),
      ),
    ], find);
    expect(result.map((c) => c.code), ['107018']);
  });

  test('order is preserved', () async {
    final result = await resolveSupplementCandidates([
      _supplement('999999'),
      _supplement('707018', alternatives: ['107018']),
    ], find);
    expect(result.map((c) => c.code), ['999999', '107018']);
  });
}
