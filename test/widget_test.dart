import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drop_share/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const DropShareApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
