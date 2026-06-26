// ════════════════════════════════════════════════════════════════
// home_screen.dart — EVA HUD 控制台 (重構版 — 分拆整理)
// ════════════════════════════════════════════════════════════════
// ★ 各功能卡片已拆分至 lib/widgets/
// ★ 共用色彩 & 组件在 lib/theme/eva_theme.dart
// ════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models/obd_pids.dart';
import '../models/hud_channel_config.dart';
import '../services/bt_manager.dart';
import '../services/dke_logger.dart';
import '../theme/eva_theme.dart';
import 'hud_sfx.dart';
import 'eva_hud_screen.dart';
import '../widgets/boot_animation.dart';
import '../widgets/comm_mode_card.dart';
import '../widgets/bt_connection_card.dart';
import '../widgets/wallpaper_card.dart';
import '../widgets/audio_settings_card.dart';
import '../widgets/core_monitor_card.dart';
import '../widgets/channel_config_card.dart';
import '../widgets/rpm_config_card.dart';
import '../widgets/full_throttle_card.dart';
import '../widgets/gear_calc_card.dart';
import '../widgets/launch_buttons.dart';
import '../widgets/vehicle_profile_card.dart';
import '../widgets/did_scanner_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── 启动 ──
  bool _booted = false;

  // ── 壁纸 (HUD 启动需要) ──
  File? _wpFile;
  double _darkness = 0.72;
  bool _wpLoaded = false;

  // ── BGM (播放器 + 状态：HUD 进出需要读写音量) ──
  final AudioPlayer _bgmPlayer = AudioPlayer();
  bool _bgmEnabled = false;
  double _bgmVolume = 0.5;

  @override
  void initState() {
    super.initState();
    BtManager.instance.addListener(_onBtChanged);
    BtManager.instance.onLog = (tag, msg) {
      DkeLogger.instance.write(tag, msg);
    };
    DkeLogger.instance.start();
    _loadCommMode();
    _loadWallpaper();
    HudSfx.instance.init();
  }

  @override
  void dispose() {
    BtManager.instance.removeListener(_onBtChanged);
    BtManager.instance.onLog = null;
    DkeLogger.instance.stop();
    _bgmPlayer.dispose();
    HudSfx.instance.dispose();
    super.dispose();
  }

  void _onBtChanged() {
    if (mounted) setState(() {});
  }

  // ═══ 通讯模式持久化 ═══

  Future<void> _loadCommMode() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(kCommMode) ?? 0;
    BtManager.instance.commMode = CommMode.values[idx.clamp(0, CommMode.values.length - 1)];
    if (Platform.isIOS) {
      BtManager.instance.linkMode = BtLinkMode.ble;
    } else {
      final linkIdx = prefs.getInt(kLinkMode) ?? 0;
      BtManager.instance.linkMode = BtLinkMode.values[linkIdx.clamp(0, 1)];
    }
    if (mounted) setState(() {});
  }

  // ═══ 壁纸持久化 ═══

  Future<void> _loadWallpaper() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(kWpPath);
    final dark = prefs.getDouble(kWpDark);
    if (mounted) {
      setState(() {
      _wpLoaded = true;
      _darkness = dark ?? 0.72;
      if (path != null && File(path).existsSync()) _wpFile = File(path);
    });
    }
  }

  // ═══ HUD 启动 ═══

  void _launchHud(bool demo) {
    if (_bgmEnabled) _bgmPlayer.setVolume(_bgmVolume * 0.3); // 进入HUD → 降到30%
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EvaHudScreen(
      startDemo: demo, wallpaper: _wpFile, darkness: _darkness,
    ))).then((_) {
      if (_bgmEnabled) _bgmPlayer.setVolume(_bgmVolume);     // 返回 → 恢复原音量
      if (mounted) setState(() {});  // ★ 触发重建 → BtConnectionCard 检查 hudDiagResult
    });
  }

  // ═══ 构建 ═══

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: DS.bg,
      body: SafeArea(
        child: _booted
          ? _mainContent()
          : BootAnimation(onComplete: () => setState(() => _booted = true)),
      ));
  }

  Widget _mainContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        _titleBanner(),
        const SizedBox(height: 16),
        CommModeCard(onChanged: () => setState(() {})),
        const SizedBox(height: 12),
        VehicleProfileCard(onProfileChanged: () => setState(() {})),
        const SizedBox(height: 12),
        BtConnectionCard(),
        const SizedBox(height: 12),
        const DidScannerCard(),
        const SizedBox(height: 12),
        if (_wpLoaded)
          WallpaperCard(
            initialFile: _wpFile,
            initialDarkness: _darkness,
            onWallpaperChanged: (f) => _wpFile = f,
            onDarknessChanged: (d) => _darkness = d,
          ),
        const SizedBox(height: 12),
        AudioSettingsCard(
          bgmPlayer: _bgmPlayer,
          onBgmStateChanged: (enabled, volume) {
            _bgmEnabled = enabled;
            _bgmVolume = volume;
          },
        ),
        const SizedBox(height: 12),
        CoreMonitorCard(key: ValueKey(HudChannelStore.corePidIds.join())),
        const SizedBox(height: 12),
        const ChannelConfigCard(),
        const SizedBox(height: 12),
        const RpmConfigCard(),
        const FullThrottleCard(),
        const SizedBox(height: 12),
        GearCalcCard(onChanged: () => setState(() {})),
        const SizedBox(height: 20),
        LaunchButtons(onLaunch: _launchHud),
        const SizedBox(height: 24),
      ]),
    );
  }

  // ═══ 标题 ═══

  Widget _titleBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: evaAmber.withOpacity(0.2)),
        color: evaAmber.withOpacity(0.02)),
      child: Column(children: [
        Text('N.E.R.V', style: TextStyle(fontFamily: 'monospace',
          fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 8,
          color: evaAmber, shadows: [
            Shadow(color: evaAmber.withOpacity(0.3), blurRadius: 20)])),
        Text('DKE戦闘座舱 1.0 | DK企鹅工程荣誉出品', style: TextStyle(fontFamily: 'monospace',
          fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 3,
          color: evaAmber.withOpacity(0.5))),
        const SizedBox(height: 4),
        Text('歲月流轉、願君の青春英雄魂は永遠に不滅！', style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w700, letterSpacing: 1,
          color: evaAmber.withOpacity(0.2))),
      ]));
  }
}