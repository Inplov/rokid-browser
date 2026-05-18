import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'browser_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const RokidBrowserApp());
}

class RokidBrowserApp extends StatelessWidget {
  const RokidBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rokid Browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF000000),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF00),
          onPrimary: Color(0xFF000000),
          surface: Color(0xFF000000),
          onSurface: Color(0xFF00FF00),
        ),
      ),
      home: const BrowserScreen(),
    );
  }
}
