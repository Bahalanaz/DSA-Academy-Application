import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsa_app/core/theme/app_theme.dart';
import 'package:dsa_app/features/parent/screens/player_form_screen.dart';

/// The parent's ADD PLAYER screen checks what was typed before anything is
/// sent: one name field holding the given name and the last name.
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark, home: const Profile(isNew: true)),
    );
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump();
  }

  testWidgets('one name field, hinted "Given name + Last name"', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('ADD PLAYER'), findsOneWidget);
    expect(find.text('Given name + Last name'), findsOneWidget);
  });

  testWidgets('saving with no name asks for both names', (tester) async {
    await open(tester);
    await save(tester);
    expect(
      find.text("Please enter the player's given name and last name"),
      findsOneWidget,
    );
  });

  testWidgets('a single word asks for the last name too', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'Juan');
    await save(tester);
    expect(
      find.text("Please add the player's last name too, like \"Juan Cruz\""),
      findsOneWidget,
    );
  });

  testWidgets('with both names, the birthday is asked for next', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, '  Juan   Cruz ');
    await save(tester);
    expect(
      find.text(
        "Please choose the player's birthday — it decides their category",
      ),
      findsOneWidget,
    );
  });
}
