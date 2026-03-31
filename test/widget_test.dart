import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poke_scan/main.dart';

void main() {
  testWidgets('manual search screen smoke test', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ManualSearchScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Manual Search'), findsOneWidget);
    expect(find.text('Look up any Pokémon card'), findsOneWidget);
  });
}
