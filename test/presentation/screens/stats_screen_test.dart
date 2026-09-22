import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/screens/stats/stats_screen.dart';
import 'package:medora/presentation/widgets/year_months_grid.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';

DateTime _day(String iso) => DateTime.parse('$iso 00:00:00');

Treatment _leave(String name, String? from, String? to, {String id = ''}) =>
    Treatment(
      id: id.isEmpty ? name : id,
      name: name,
      startDate: _day(from ?? '2026-01-01'),
      sickLeaveFrom: from == null ? null : _day(from),
      sickLeaveTo: to == null ? null : _day(to),
    );

/// A treatment list that is already loaded, so the screen never waits.
class _Treatments extends TreatmentListNotifier {
  _Treatments(this.treatments);

  final List<Treatment> treatments;

  @override
  Future<List<Treatment>> build() async => treatments;
}

Future<void> _pumpStats(
  WidgetTester tester,
  List<Treatment> treatments, {
  DateTime? now,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(412, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpMedoraApp(
    tester,
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: const StatsScreen(),
      ),
    ),
    overrides: [
      treatmentListProvider.overrideWith(() => _Treatments(treatments)),
      nowProvider.overrideWithValue(() => now ?? _day('2026-06-15')),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('counts the days of the current year', (tester) async {
    await _pumpStats(tester, [
      _leave('Flu', '2026-03-02', '2026-03-06'), // 5
      _leave('Back', '2026-03-04', '2026-03-07'), // 4, two shared
    ]);

    // Six, not nine: the shared days are counted once.
    expect(find.text('6 days'), findsOneWidget);
    expect(find.text('2 episodes'), findsOneWidget);
    expect(find.text('2026'), findsOneWidget);
  });

  testWidgets('an empty year says so rather than looking broken', (
    tester,
  ) async {
    await _pumpStats(tester, [_leave('Vitamins', null, null)]);

    expect(
      find.text('Record sick leave on a treatment and this fills in.'),
      findsOneWidget,
    );
    // The grid is still drawn: an empty year is a shape too.
    expect(find.byType(YearMonthsGrid), findsOneWidget);
  });

  testWidgets('a year with no leave, in a history that has some, says which', (
    tester,
  ) async {
    await _pumpStats(tester, [_leave('Flu', '2024-03-02', '2024-03-06')]);

    // Opens on 2026, which is empty, while 2024 is not.
    expect(find.text('No sick leave recorded in 2026.'), findsOneWidget);
  });

  testWidgets('stepping back a year recounts', (tester) async {
    await _pumpStats(tester, [
      _leave('Flu', '2026-03-02', '2026-03-03', id: 'a'),
      _leave('Cold', '2025-01-05', '2025-01-09', id: 'b'),
    ]);

    expect(find.text('2 days'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stats_prev_year')));
    await tester.pumpAndSettle();

    expect(find.text('2025'), findsOneWidget);
    expect(find.text('5 days'), findsOneWidget);
  });

  testWidgets('the stepper stops at the first year with any leave', (
    tester,
  ) async {
    await _pumpStats(tester, [_leave('Flu', '2026-03-02', '2026-03-03')]);

    final back = tester.widget<IconButton>(
      find.byKey(const Key('stats_prev_year')),
    );
    final forward = tester.widget<IconButton>(
      find.byKey(const Key('stats_next_year')),
    );

    expect(back.onPressed, isNull, reason: 'nothing before 2026 to show');
    expect(forward.onPressed, isNull, reason: 'the future is not a year yet');
  });

  testWidgets('compares with last year', (tester) async {
    await _pumpStats(tester, [
      _leave('Flu', '2026-03-02', '2026-03-03', id: 'a'), // 2
      _leave('Cold', '2025-01-05', '2025-01-09', id: 'b'), // 5
    ]);

    expect(find.textContaining('3 days fewer'), findsOneWidget);
  });

  testWidgets('an open leave counts up to today', (tester) async {
    await _pumpStats(tester, [_leave('Ongoing', '2026-06-13', null)]);

    expect(find.text('3 days'), findsOneWidget);
  });

  testWidgets('ranks the illnesses and warns that overlap double-counts', (
    tester,
  ) async {
    await _pumpStats(tester, [
      _leave('Flu', '2026-03-02', '2026-03-06'),
      _leave('Back', '2026-03-04', '2026-03-07'),
    ]);

    expect(find.text('Flu'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(
      find.textContaining('can add up to more than the total'),
      findsOneWidget,
    );
  });

  testWidgets('tapping a sick day names the illness', (tester) async {
    await _pumpStats(tester, [_leave('Flu', '2026-03-02', '2026-03-06')]);

    await tester.tap(
      find.byKey(YearMonthsGrid.cellKey(_day('2026-03-04'))),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Flu'), findsWidgets);
  });

  testWidgets('holds together at a 1.6x text scale', (tester) async {
    await _pumpStats(tester, [
      _leave('Influenza mit Komplikationen', '2026-03-02', '2026-03-06'),
      _leave('Rückenverletzung', '2026-05-04', '2026-05-09'),
    ], scale: 1.6);

    expect(tester.takeException(), isNull);
  });
}
