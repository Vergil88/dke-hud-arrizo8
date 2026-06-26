// ════════════════════════════════════════════════════════════════════
// OLED 显示增强辅助 (Android + iOS)
// ════════════════════════════════════════════════════════════════════
// 1. 屏幕常亮 (WakeLock)        — wakelock_plus
// 2. 亮度拉满 / 恢复            — screen_brightness
// 3. 全部 try-catch, 缺依赖时静默降级
// ════════════════════════════════════════════════════════════════════
//
// pubspec.yaml 需添加:
//   wakelock_plus: ^1.2.8
//   screen_brightness: ^1.0.1
// ════════════════════════════════════════════════════════════════════

import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

class OledHelper {
  OledHelper._();
  static final instance = OledHelper._();

  double _savedBrightness = -1;
  bool _boosted = false;

  // ── 亮度控制 ────────────────────────────────

  Future<void> boostBrightness() async {
    if (_boosted) return;
    _boosted = true;
    try {
      _savedBrightness = await ScreenBrightness().current;
      await ScreenBrightness().setScreenBrightness(1.0);
    } catch (_) {}
  }

  Future<void> restoreBrightness() async {
    if (!_boosted) return;
    _boosted = false;
    try {
      if (_savedBrightness >= 0) {
        await ScreenBrightness().setScreenBrightness(_savedBrightness);
      } else {
        await ScreenBrightness().resetScreenBrightness();
      }
    } catch (_) {}
    _savedBrightness = -1;
  }

  // ── 屏幕常亮 ──────────────────────────────────

  Future<void> keepScreenOn() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> releaseScreen() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }
}