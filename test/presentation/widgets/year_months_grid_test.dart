import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/year_months_grid.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';

DateTime _day(String iso) => DateTime.parse('$iso 00:00:00');

/// The grid for [year], with [sick] filled in, on a 412 px phone.
Future<void> _pumpGrid(
  WidgetTester tester, {
  int year = 2026,
  Set<DateTime> sick = const {},
  DateTime? today,
  double scale = 1,
  void Function(DateTime)? onDayTap,
}) async {
  tester.view.physicalSize = const Size(412, 1600);
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
        child: Scaffold(
          body: SingleChildScrollView(
            child: YearMonthsGrid(
              year: year,
              sickDays: sick,
              today: today ?? _day('2026-06-15'),
              onDayTap: onDayTap,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The cell for [date], found by the key the grid gives it.
Finder _cell(DateTime date) => find.byKey(YearMonthsGrid.cellKey(date));

void main() {
  setUpAll(loadAppFonts);

  testWidgets('draws twelve months', (tester) async {
    await _pumpGrid(tester);

    expect(find.text('January'), findsOneWidget);
    expect(find.text('December'), findsOneWidget);
    // Every day of a non-leap year has a cell.
    expect(find.byType(YearDayCell), findsNWidgets(365));
  });

  testWidgets('a leap year has its 29th of February', (tester) async {
    await _pumpGrid(tester, year: 2028);

    expect(_cell(_day('2028-02-29')), findsOneWidget);
    expect(find.byType(YearDayCell), findsNWidgets(366));
  });

  testWidgets('a sick day is filled and a well day is not', (tester) async {
    await _pumpGrid(tester, sick: {_day('2026-03-04')});

    final sick = tester.widget<YearDayCell>(_cell(_day('2026-03-04')));
    final well = tester.widget<YearDayCell>(_cell(_day('2026-03-05')));

    expect(sick.isSick, isTrue);
    expect(well.isSick, isFalse);
  });

  testWidgets('today is marked, and a day after it reads as future', (
    tester,
  ) async {
    await _pumpGrid(tester, today: _day('2026-06-15'));

    expect(
      tester.widget<YearDayCell>(_cell(_day('2026-06-15'))).isToday,
      isTrue,
    );
    expect(
      tester.widget<YearDayCell>(_cell(_day('2026-06-14'))).isToday,
      isFalse,
    );
    expect(
      tester.widget<YearDayCell>(_cell(_day('2026-06-16'))).isFuture,
      isTrue,
    );
    expect(
      tester.widget<YearDayCell>(_cell(_day('2026-06-14'))).isFuture,
      isFalse,
    );
  });

  testWidgets('the blanks before the 1st put it on the right weekday', (
    tester,
  ) async {
    // 1 February 2026 is a Sunday, the last column of a Monday-first week —
    // the case an off-by-one in the leading blanks gets wrong.
    await _pumpGrid(tester);

    final first = tester.getCenter(_cell(_day('2026-02-01')));
    final monday = tester.getCenter(_cell(_day('2026-02-02')));

    expect(
      first.dx,
      greaterThan(monday.dx),
      reason: 'the Sunday should sit at the end of its week, not the start',
    );
    expect(
      monday.dy,
      greaterThan(first.dy),
      reason: 'the Monday after it belongs to the next row',
    );
  });

  testWidgets('tapping a day reports its date', (tester) async {
    final tapped = <DateTime>[];
    await _pumpGrid(tester, sick: {_day('2026-03-04')}, onDayTap: tapped.add);

    await tester.tap(_cell(_day('2026-03-04')));
    await tester.pumpAndSettle();

    expect(tapped, [_day('2026-03-04')]);
  });

  testWidgets('a future day is not tappable', (tester) async {
    final tapped = <DateTime>[];
    await _pumpGrid(tester, onDayTap: tapped.add);

    await tester.tap(_cell(_day('2026-06-16')), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(tapped, isEmpty);
  });

  testWidgets('survives a 1.6x text scale without overflowing', (tester) async {
    await _pumpGrid(tester, scale: 1.6);

    expect(tester.takeException(), isNull);
  });
}
