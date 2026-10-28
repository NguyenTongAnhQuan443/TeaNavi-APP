import 'package:flutter_test/flutter_test.dart';
import 'package:teanavi_map/main.dart';

void main() {
  testWidgets('TeaNavi smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TeaNaviApp());
    expect(find.text('TeaNavi Map'), findsOneWidget);
  });
}
