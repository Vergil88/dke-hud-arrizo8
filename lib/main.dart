// ════════════════════════════════════════════════════════════════
// main.dart — EVA HUD 独立 App 入口 (重构版)
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/hud_channel_config.dart';
import 'models/vehicle_profile.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF000000),
  ));

  // ★ 初始化车型配置 (恢复上次选择)
  await ProfileManager.instance.init();

  await HudChannelStore.load();

  runApp(const EvaHudApp());
}

// ═══ 设计系统 ═══
class DS {
  static const bg        = Color(0xFF08080A);
  static const surface   = Color(0xFF111114);
  static const surfaceHi = Color(0xFF1A1A1F);
  static const border    = Color(0xFF222228);
  static const borderHi  = Color(0xFF333340);

  static const textPri   = Color(0xFFE8E8EC);
  static const textSec   = Color(0xFF8888A0);
  static const textDim   = Color(0xFF4A4A5A);

  static const green     = Color(0xFF00E676);
  static const greenDim  = Color(0xFF0A3D1F);
  static const red       = Color(0xFFFF1744);
  static const redDim    = Color(0xFF3D0A14);
  static const cyan      = Color(0xFF00E5FF);
  static const amber     = Color(0xFFFFD740);
  static const teal      = Color(0xFF1DE9B6);
  static const tealDim   = Color(0xFF0A3D30);

  static const logTx     = Color(0xFF40C4FF);
  static const logRx     = Color(0xFFFFD740);
  static const logErr    = Color(0xFFFF5252);
  static const logSys    = Color(0xFF666680);

  static const radius    = 10.0;
  static const radiusSm  = 6.0;
}

class EvaHudApp extends StatelessWidget {
  const EvaHudApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EVA HUD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: DS.bg,
        splashFactory: InkSparkle.splashFactory,
      ),
      home: const HomeScreen(),
    );
  }
}