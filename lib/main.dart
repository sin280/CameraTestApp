import 'package:flutter/material.dart';
import 'official_camera_preview_screen.dart';
// 既存のCamerAwesome画面: import 'camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Encryption Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 公式cameraパッケージの16:9検証画面に差し替え
      // 元に戻す場合: home: const CameraScreen(),
      home: const OfficialCameraPreviewScreen(),
    );
  }
}
