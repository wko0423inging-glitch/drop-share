import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const DropShareApp());
}

class DropShareApp extends StatefulWidget {
  const DropShareApp({super.key});

  @override
  State<DropShareApp> createState() => _DropShareAppState();
}

class _DropShareAppState extends State<DropShareApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DropShare',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(
        onThemeModeChanged: (ThemeMode mode) {
          setState(() => _themeMode = mode);
        },
      ),
    );
  }
}
