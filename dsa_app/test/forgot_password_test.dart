import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsa_app/core/theme/app_theme.dart';
import 'package:dsa_app/features/auth/screens/forgot_password_screen.dart';

void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark, home: const ForgotPassword()),
    );
  }

  testWidgets('Forgot Password starts by asking for the email or username', (
    tester,
  ) async {
    await open(tester);
    expect(find.text("FORGOT PASSWORD?"), findsOneWidget);
    expect(find.text("SEND CODE"), findsOneWidget);
    expect(find.text("Back to Log In"), findsOneWidget);
    // The code and new-password fields only come after a code is sent.
    expect(find.text("RESET PASSWORD"), findsNothing);
  });

  testWidgets('Sending with nothing typed asks for it (no server call)', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text("SEND CODE"));
    await tester.pump();
    expect(find.text("Please enter your email or username"), findsOneWidget);
    expect(find.text("CHECK YOUR EMAIL"), findsNothing);
  });
}
