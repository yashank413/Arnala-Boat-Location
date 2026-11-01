
import 'package:flutter_test/flutter_test.dart';
import 'package:arnala_boat/main.dart';

void main() {
  testWidgets('Boat tracking screen displays correctly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ArnalaBoatApp());

    expect(find.text('Arnala Boat Tracker'), findsOneWidget);
    expect(find.text('Arnala ↔ Arnala Killa'), findsOneWidget);
    expect(find.text('Map will appear here'), findsOneWidget);
    expect(
      find.text('Live tracking is not connected yet'),
      findsOneWidget,
    );
  });
}
