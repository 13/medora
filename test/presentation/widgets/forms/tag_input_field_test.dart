import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/forms/tag_input_field.dart';

import '../../../helpers/pump_app.dart';

void main() {
  testWidgets('adds on submit, ignores duplicates, deletes via chip', (tester) async {
    var tags = <String>['aspirin'];
    late StateSetter setOuter;
    await pumpMedoraApp(
      tester,
      StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        return Scaffold(
          body: TagInputField(
            label: 'Active ingredients',
            icon: Icons.science,
            tags: tags,
            onChanged: (t) => setOuter(() => tags = t),
          ),
        );
      }),
    );

    await tester.enterText(find.byType(TextField), 'ibuprofen');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tags, ['aspirin', 'ibuprofen']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

    await tester.enterText(find.byType(TextField), 'aspirin');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tags, ['aspirin', 'ibuprofen']);

    await tester.tap(find.descendant(of: find.widgetWithText(InputChip, 'aspirin'), matching: find.byIcon(Icons.cancel)));
    await tester.pumpAndSettle();
    expect(tags, ['ibuprofen']);
  });
}
