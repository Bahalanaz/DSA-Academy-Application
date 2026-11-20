import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsa_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A phone with no remembered login: secure storage answers "nothing
  // saved" to everything.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  testWidgets('App launches and shows the welcome screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    // The app first checks for a remembered login, then fades to the
    // welcome screen.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text("WE TRAIN. WE DEVELOP."), findsOneWidget);
    expect(find.text("LOG IN"), findsOneWidget);
    expect(find.text("CREATE ACCOUNT"), findsOneWidget);
  });
}
