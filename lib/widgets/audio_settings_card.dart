// ════════════════════════════════════════════════════════════════
// audio_settings_card.dart — 音声設定卡片
// ════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../screens/hud_sfx.dart';
import '../theme/eva_theme.dart';

class AudioSettingsCard extends StatefulWidget {
  /// 外部传入的 BGM 播放器（由 HomeScreen 持有，HUD 启动时需调节音量）
  final AudioPlayer bgmPlayer;
  /// BGM 开关或音量变化时回调，HomeScreen 需要这两个值来处理 HUD 进出音量
  final void Function(bool enabled, double volume)? onBgmStateChanged;

  const AudioSettingsCard({super.key, required this.bgmPlayer, this.onBgmStateChanged});
  @override State<AudioSettingsCard> createState() => _AudioSettingsCardState();
}

class _AudioSettingsCardState extends State<AudioSettingsCard> {
  bool _bgmEnabled = false;
  double _bgmVolume = 0.5;
  double _sfxVolume = 0.8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final on = prefs.getBool(kBgmOn) ?? false;
    final bgmVol = prefs.getDouble(kBgmVol) ?? 0.5;
    final sfxVol = prefs.getDouble(kSfxVol) ?? 0.8;
    final interrupt = prefs.getBool(kAlertOverlap) ?? true;
    if (mounted) {
      setState(() {
        _bgmEnabled = on; _bgmVolume = bgmVol; _sfxVolume = sfxVol;
      });
      HudSfx.instance.volume = sfxVol;
      HudSfx.instance.overlapMode = interrupt
          ? AlertOverlapMode.interrupt : AlertOverlapMode.simultaneous;
      _notifyParent();
      if (on) _startBgm();
    }
  }

  /// 同步 BGM 状态给 HomeScreen（用于 HUD 进出音量控制）
  void _notifyParent() {
    widget.onBgmStateChanged?.call(_bgmEnabled, _bgmVolume);
  }

  Future<void> _toggleBgm(bool on) async {
    setState(() => _bgmEnabled = on);
    _notifyParent();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBgmOn, on);
    on ? _startBgm() : await widget.bgmPlayer.stop();
  }

  Future<void> _startBgm() async {
    try {
      final file = Platform.isIOS ? 'sfx/evabgm.aac' : 'sfx/evabgm.ogg';
      await widget.bgmPlayer.setReleaseMode(ReleaseMode.loop);
      await widget.bgmPlayer.setVolume(_bgmVolume);
      await widget.bgmPlayer.play(AssetSource(file));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return EvaCard(title: 'AUDIO', subtitle: '音声設定',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_bgmEnabled ? Icons.music_note : Icons.music_off,
            color: _bgmEnabled ? evaAmber : DS.textDim, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(_bgmEnabled ? 'BGM — 再生中' : 'BGM — OFF',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _bgmEnabled ? evaAmber.withOpacity(0.8) : DS.textDim))),
          SizedBox(height: 28, child: Switch.adaptive(
            value: _bgmEnabled, activeColor: evaAmber, onChanged: _toggleBgm)),
        ]),
        const SizedBox(height: 8),
        evaAudioSlider('BGM VOL', _bgmVolume, evaAmber.withOpacity(0.6), (v) {
          setState(() => _bgmVolume = v); widget.bgmPlayer.setVolume(v);
          _notifyParent();
          SharedPreferences.getInstance().then((p) => p.setDouble(kBgmVol, v)); }),
        const SizedBox(height: 4),
        evaAudioSlider('ALERT VOL', _sfxVolume, evaRed.withOpacity(0.6), (v) {
          setState(() => _sfxVolume = v); HudSfx.instance.volume = v;
          SharedPreferences.getInstance().then((p) => p.setDouble(kSfxVol, v)); }),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final e in HudSfx.registry)
            evaMiniBtn('▶ ${e.displayName}', () => HudSfx.instance.play(e.id)),
        ]),
        const SizedBox(height: 10),
        // ★ 警告音重叠模式
        Row(children: [
          Icon(Icons.layers, size: 14,
            color: HudSfx.instance.overlapMode == AlertOverlapMode.simultaneous
                ? evaCyan : DS.textDim),
          const SizedBox(width: 8),
          Expanded(child: Text(
            HudSfx.instance.overlapMode == AlertOverlapMode.simultaneous
                ? '同時再生 — 警報音を重ねる' : '割込 — 新しい警報が旧い警報を停止',
            style: TextStyle(fontFamily: 'monospace', fontSize: 9,
              fontWeight: FontWeight.w700,
              color: HudSfx.instance.overlapMode == AlertOverlapMode.simultaneous
                  ? evaCyan.withOpacity(0.8) : DS.textDim))),
          SizedBox(height: 28, child: Switch.adaptive(
            value: HudSfx.instance.overlapMode == AlertOverlapMode.simultaneous,
            activeColor: evaCyan,
            onChanged: (v) async {
              setState(() {
                HudSfx.instance.overlapMode = v
                    ? AlertOverlapMode.simultaneous
                    : AlertOverlapMode.interrupt;
              });
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(kAlertOverlap, !v);
            })),
        ]),
      ]));
  }
}
