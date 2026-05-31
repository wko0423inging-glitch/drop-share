import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const DropShareApp());
}

class DropShareApp extends StatelessWidget {
  const DropShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DropShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
