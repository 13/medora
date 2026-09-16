import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';

import '../../../helpers/pump_app.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15, 30);

  /// Pumps an empty field with the given bounds, opens its picker, confirms
  /// the initial date and returns what the field reported.
  Future<DateTime?> pickInitial(
    WidgetTester tester, {
    DateTime? firstDate,
    DateTime? lastDate,
    DateTime? date,
  }) async {
    DateTime? picked;
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: DatePickerField(
          label: 'When',
          icon: Icons.event,
          date: date,
          now: now,
          firstDate: firstDate,
          lastDate: lastDate,
          onDateSelected: (d) => picked = d,
        ),
      ),
    );
    await tester.tap(find.text(date == null ? 'Select date' : 'When'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('opens on today when today is inside the bounds', (tester) async {
    expect(await pickInitial(tester), DateTime(2026, 3, 4));
  });

  testWidgets('opens on firstDate when today is before it', (tester) async {
    expect(
      await pickInitial(tester, firstDate: DateTime(2026, 3, 10)),
      DateTime(2026, 3, 10),
    );
  });

  testWidgets('opens on lastDate when today is after it', (tester) async {
    expect(
      await pickInitial(tester, lastDate: DateTime(2026, 2, 20)),
      DateTime(2026, 2, 20),
    );
  });

  testWidgets('a value before firstDate opens on firstDate', (tester) async {
    // A stored range that ends before it starts: the end field's value is
    // before the start date that bounds it.
    expect(
      await pickInitial(
        tester,
        date: DateTime(2026, 3, 2),
        firstDate: DateTime(2026, 3, 9),
      ),
      DateTime(2026, 3, 9),
    );
  });

  testWidgets('a firstDate later in the same day as now still opens', (
    tester,
  ) async {
    // Only the calendar date matters: a start date of today (midnight) and
    // a now of 15:30 are the same day.
    expect(
      await pickInitial(tester, firstDate: DateTime(2026, 3, 4, 23)),
      DateTime(2026, 3, 4),
    );
  });
}
