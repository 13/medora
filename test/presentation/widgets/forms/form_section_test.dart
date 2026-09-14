import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';

import '../../../helpers/pump_app.dart';

void main() {
  testWidgets('collapsed section fields stay registered with the Form and validate', (tester) async {
    final formKey = GlobalKey<FormState>();
    final notifier = ValueNotifier<bool>(false);
    addTearDown(notifier.dispose);

    await pumpMedoraApp(
      tester,
      Scaffold(
        body: Form(
          key: formKey,
          child: FormSection(
            title: 'Section',
            icon: Icons.info,
            initiallyExpanded: false,
            controller: notifier,
            children: [
              TextFormField(
                validator: (value) {
                  notifier.value = true;
                  return 'always fails';
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(notifier.value, isFalse);
    expect(formKey.currentState!.validate(), isFalse);
    expect(notifier.value, isTrue);
  });

  testWidgets('manual collapse writes back to the controller so a later force-expand works twice', (tester) async {
    final n = ValueNotifier<bool>(true);
    addTearDown(n.dispose);

    await pumpMedoraApp(
      tester,
      Scaffold(
        body: FormSection(
          title: 'Section',
          icon: Icons.info,
          controller: n,
          initiallyExpanded: true,
          children: const [Text('body')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('body'), findsOneWidget);

    await tester.tap(find.text('Section'));
    await tester.pumpAndSettle();

    expect(n.value, isFalse);
    expect(find.text('body'), findsNothing);

    n.value = true;
    await tester.pumpAndSettle();

    expect(find.text('body'), findsOneWidget);

    await tester.tap(find.text('Section'));
    await tester.pumpAndSettle();

    expect(n.value, isFalse);

    n.value = true;
    await tester.pumpAndSettle();

    expect(find.text('body'), findsOneWidget);
  });
}
