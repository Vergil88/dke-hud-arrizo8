// ════════════════════════════════════════════════════════════════
// eva_hud_screen.dart — EVA HUD 全屏编排器 (v2 重构)
// ════════════════════════════════════════════════════════════════
// ★ 警报检测: 遍历全部 6 通道, 由 ChannelConfig 驱动
// ★ 音效: 统一调用 HudSfx.play(config.alertSfxId)
// ★ 升档: 独立于通道体系
// ════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../models/obd_pids.dart';
import '../models/hud_channel_config.dart';
import '../services/live_data_service.dart';
import '../services/bt_manager.dart';
import 'hud_shared.dart';
import 'hud_skin.dart';
import 'hud_sfx.dart';
import 'oled_helper.dart';
import 'hud_page_eva.dart';
import 'hud_interpolator.dart';

class EvaHudScreen extends StatefulWidget {
  final bool startDemo;
  final File? wallpaper;
  final double darkness;
  const EvaHudScreen({
    super.key,
    this.startDemo = false,
    this.wallpaper,
    this.darkness = 0.72,
  });
  @override State<EvaHudScreen> createState() => _EvaHudScreenState();
}

class _EvaHudScreenState extends State<EvaHudScreen>
    with SingleTickerProviderStateMixin {
  bool _alive = true;
  late final LiveDataService _can;
  final Map<String, double> _d = {};
  int _latMs = 0;
  double _hz = 0;
  int _hzCount = 0;
  int _hzSumMs = 0;
  bool _flashOn = false;
  int _tick = 0;

  final _interp = HudInterpolator();
  late final Ticker _renderTicker;
  int _flashTick = 0;

  double _peakBoost = 0, _peakTorque = 0, _peakLatG = 0, _peakLonG = 0;
  double _boostPeakHold = 0;
  int _boostPeakTick = 0;
  double _gLon = 0, _gLat = 0, _prevSpeed = 0;
  int _prevGear = 0, _gearChangeKey = 0;
  bool _slipping = false;

  // ── 升档警报 (独立) ──
  bool _wShift = false;
  bool _prevShift = false;

  // ── 全力全開警报 (独立) ──
  bool _wFullThrottle = false;
  bool _prevFullThrottle = false;
  int _fullThrottleTicks = 0;  // ★ 持続 tick カウンタ
  int _ftExitTick = 0;         // ★ 退出動画カウンタ (0=非活性, 1-20=退出中)
  int _ftPeakTick = 0;         // ★ 解除時の fullThrottleTicks 値

  // ── ★ 通道警报状态 (数据驱动) ──
  final List<ActiveAlert> _activeAlerts = [];
  Set<HudSlot> _prevDangerSlots = {};
  bool _prevBrightBoosted = false;

  // ── ★ 多重警報輪播系統 ──
  int _displayAlertIdx = 0;          // 当前显示的警报索引
  int _rotationTick = 0;             // 上次轮播切换的 tick
  final Map<HudSlot, int> _slotShownTicks = {};  // 每 slot 累计显示 tick
  static const _kRotationInterval = 60;    // 2s @30fps
  static const _kDecayThreshold = 300;     // 10s @30fps 后开始衰减
  static const _kRestoreRate = 1;          // 不显示时每 tick 恢复 1
  List<int> _alertShownTicksList = [];     // 与 _activeAlerts 同索引
  bool _multiCrisis = false;               // 3+ 活跃警报

  double _v(String semantic) {
    const map = {
      'rpm':      ['uds_rpm'],
      'speed':    ['uds_speed'],
      'boost':    ['uds_boost_b1'],
      'torque':   ['uds_torque'],
      'throttle': ['uds_accel'],
      'gear':     [],
    };
    final keys = map[semantic] ?? [];
    for (final k in keys) {
      final v = _d[k];
      if (v != null) return v;
    }
    return 0;
  }

  List<ObdPid> _buildSelectedPids() {
    final ids = HudChannelStore.requiredPidIds;
    final mode = BtManager.instance.commMode;
    return ids.map((id) => ObdPids.byIdForMode(id, mode)).whereType<ObdPid>().toList();
  }

  @override void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _interp.registerDefaults();
    _renderTicker = createTicker(_onRenderTick)..start();

    _can = LiveDataService(
      onLog: (tag, msg) => BtManager.instance.onLog?.call(tag, msg),
      onData: (s) { if (_alive && mounted) _onData(s); },
      onLatency: (ms) {
        if (!_alive || !mounted) return;
        _hzCount++;
        _hzSumMs += ms;
        if (_hzCount >= 5) {
          _latMs = ms;
          _hz = _hzSumMs > 0 ? _hzCount * 1000.0 / _hzSumMs : 0;
          _hzCount = 0;
          _hzSumMs = 0;
        }
      },
    );
    OledHelper.instance.keepScreenOn();
    OledHelper.instance.boostBrightness();  // ★ HUD 模式: 屏幕常亮 + 亮度最大
    HudSfx.instance.setHudMode(true);  // ★ HUD 模式: alarm 音频流, 警報音効最大音量
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_alive) return;
      widget.startDemo ? _startDemo() : _startReal();
    });
  }

  @override void dispose() {
    _alive = false;
    _renderTicker.dispose();
    _can.stop();
    HudSfx.instance.stopAll();
    HudSfx.instance.setHudMode(false);  // ★ 退出 HUD: 恢复普通音频流
    OledHelper.instance.restoreBrightness();
    OledHelper.instance.releaseScreen();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ════════════════════════════════════════════════════
  // 30fps 渲染回调
  // ════════════════════════════════════════════════════

  void _onRenderTick(Duration elapsed) {
    if (!_alive || !mounted) return;

    final newFlashTick = elapsed.inMilliseconds ~/ 100;
    if (newFlashTick != _flashTick) {
      _flashTick = newFlashTick;
      _flashOn = !_flashOn;
    }

    final changed = _interp.tick();
    if (!changed && _tick > 0) return;

    _d.addAll(_interp.displayValues);

    setState(() {
      _d['rpm']           = _v('rpm');
      _d['speed']         = _v('speed');
      _d['torque_actual'] = _v('torque');
      _d['accel_pedal']   = _v('throttle');
      _d['boost_target']  = _d['uds_boost_b1'] ?? 0;

      // ── 档位 (常時有効: 計算値 or OBD 実値) ──
      final rpm = _d['rpm']!;
      final spd = _d['speed'] ?? 0;
      if (HudChannelStore.gearSource == GearSource.obdPid) {
        // OBD 实际档位: 通过 GearMapping 将 ECU 原始值标准化
        final gearPidId = HudChannelStore.selectedGearPidId;
        final rawGear = _d[gearPidId] ?? 0;
        final pid = ObdPids.byId(gearPidId);
        final mapped = pid?.gearMapping?.standardize(rawGear) ?? rawGear.round();
        _d['gear'] = mapped.toDouble();
      } else {
        _d['gear'] = HudChannelStore.calcGear(rpm, spd).toDouble();
      }

      final boost = _d['boost_target']!;
      final torque = _d['torque_actual']!;
      final throttle = _d['accel_pedal']!;
      final gear = _d['gear']!.round();

      // ── 升档警报 (独立) ──
      _wShift = rpm >= HudChannelStore.shiftRpm;
      if (_wShift && !_prevShift) HudSfx.instance.playUpshift();
      _prevShift = _wShift;

      // ── 全力全開警报 (独立) ──
      if (HudChannelStore.fullThrottleEnabled) {
        final thr = HudChannelStore.fullThrottleThreshold;
        final wasActive = _wFullThrottle; // ★ 解除検出用に旧値を保存
        // ★ 迟滞 (Hysteresis): 进入需 >= threshold, 退出需 < threshold - 5
        if (!_wFullThrottle) {
          _wFullThrottle = throttle >= thr;
        } else {
          _wFullThrottle = throttle >= (thr - 5.0);
        }
        if (_wFullThrottle && !_prevFullThrottle) HudSfx.instance.playFullThrottle();
        _prevFullThrottle = _wFullThrottle;
        // ★ 持続カウンタ
        if (_wFullThrottle) {
          _fullThrottleTicks++;
          _ftPeakTick = _fullThrottleTicks; // 常にピーク更新
          _ftExitTick = 0;                  // 活性中は退出リセット
        } else {
          // ★ 解除エッジ: wasActive → !_wFullThrottle
          if (wasActive && _ftExitTick == 0) {
            _ftExitTick = 1; // 退出動画開始
          }
          _fullThrottleTicks = 0;
        }
        // ★ 退出カウンタ進行 (活性中でない時のみ)
        if (_ftExitTick > 0 && !_wFullThrottle) {
          _ftExitTick++;
          if (_ftExitTick > 20) _ftExitTick = 0; // 完了 (~0.67s)
        }
      } else {
        _wFullThrottle = false;
        _prevFullThrottle = false;
        _fullThrottleTicks = 0;
        _ftExitTick = 0;
      }

      // ════════════════════════════════════════════════
      // ★ 通道警报检测 — 遍历全部 6 通道
      // ════════════════════════════════════════════════
      _activeAlerts.clear();
      bool anyBrightness = false;
      final nowDangerSlots = <HudSlot>{};

      for (final slot in HudSlot.values) {
        final ch = HudChannelStore.get(slot);
        final val = _d[ch.pidId] ?? 0;

        if (ch.isDanger(val) && ch.alertStyle != AlertStyle.none) {
          // ★ 守衛条件: 有 guard PID 时, 必须同时满足才触发
          if (ch.alertGuardPidId != null) {
            final guardVal = _d[ch.alertGuardPidId!] ?? 0;
            if (guardVal < ch.alertGuardMinValue) continue;
          }

          nowDangerSlots.add(slot);

          // 边沿检测: 首次进入 danger → 播放音效
          if (!_prevDangerSlots.contains(slot)) {
            if (ch.alertSfxId != 'none') {
              HudSfx.instance.play(ch.alertSfxId);
            }
          }

          _activeAlerts.add(ActiveAlert(
            slot: slot,
            style: ch.alertStyle,
            titleJp: ch.alertTitleJp,
            titleEn: ch.alertTitleEn,
            value: val,
            unit: ch.unit,
          ));

          if (ch.alertBoostBrightness) anyBrightness = true;
        }
      }
      _prevDangerSlots = nowDangerSlots;

      // ════════════════════════════════════════════════
      // ★ 多重警報輪播 + 優先度衰減
      // ════════════════════════════════════════════════
      if (_activeAlerts.length > 1) {
        // -- 累计显示 tick: 当前显示的 slot +1, 其余恢复 --
        final displayedSlot = _displayAlertIdx < _activeAlerts.length
            ? _activeAlerts[_displayAlertIdx].slot : null;
        for (final a in _activeAlerts) {
          if (a.slot == displayedSlot) {
            _slotShownTicks[a.slot] = (_slotShownTicks[a.slot] ?? 0) + 1;
          } else {
            final cur = _slotShownTicks[a.slot] ?? 0;
            if (cur > 0) _slotShownTicks[a.slot] = cur - _kRestoreRate;
          }
        }

        // -- 轮播: 每 _kRotationInterval tick 切换到下一个最高有效优先级 --
        if (_tick - _rotationTick >= _kRotationInterval) {
          _rotationTick = _tick;
          // 按有效优先级排序, 选出当前未显示的最高优先级
          int bestIdx = 0;
          int bestEP = -1;
          for (int i = 0; i < _activeAlerts.length; i++) {
            final a = _activeAlerts[i];
            final shown = _slotShownTicks[a.slot] ?? 0;
            final ep = a.effectivePriority(shown, decayAfter: _kDecayThreshold);
            // 优先选未在显示的; 同优先级选显示时间最短的
            if (ep > bestEP || (ep == bestEP && shown < (_slotShownTicks[_activeAlerts[bestIdx].slot] ?? 0))) {
              bestEP = ep;
              bestIdx = i;
            }
          }
          _displayAlertIdx = bestIdx;
        }
        // 确保索引有效
        _displayAlertIdx = _displayAlertIdx.clamp(0, _activeAlerts.length - 1);
      } else if (_activeAlerts.length == 1) {
        _displayAlertIdx = 0;
        _slotShownTicks[_activeAlerts[0].slot] =
            (_slotShownTicks[_activeAlerts[0].slot] ?? 0) + 1;
      } else {
        _displayAlertIdx = 0;
        // 无警报时逐步清零全部 shownTicks
        for (final k in _slotShownTicks.keys.toList()) {
          final v = _slotShownTicks[k]!;
          if (v > 0) {
            _slotShownTicks[k] = (v - _kRestoreRate * 3).clamp(0, 999999);
          } else {
            _slotShownTicks.remove(k);
          }
        }
      }

      // 构建 alertShownTicks 列表 (与 _activeAlerts 同索引)
      _alertShownTicksList = _activeAlerts
          .map((a) => _slotShownTicks[a.slot] ?? 0).toList();
      _multiCrisis = _activeAlerts.length >= 3;

      // OLED 亮度: HUD 模式始终最大亮度 (initState 中已设置)
      // 不再跟随警报切换, 避免警报结束时降低亮度
      _prevBrightBoosted = anyBrightness;

      // ── 其他状态 ──
      if (gear != _prevGear && gear > 0 && _prevGear > 0) _gearChangeKey++;
      _prevGear = gear;
      if (_can.isDemo) {
        _slipping = throttle > 90 && gear <= 2 && boost > 20 && spd > 10 && spd < 100;
      }

      final dv = (spd - _prevSpeed) / 3.6;
      const dt = 0.033;
      _gLon = (dv / dt / 9.81).clamp(-2.0, 2.0);
      _prevSpeed = spd;
      if (_can.isDemo) {
        final t = _tick * 0.033;
        _gLat = math.sin(t * 0.7) * (spd / 200).clamp(0.0, 1.0) * 1.2;
      }

      if (boost > _peakBoost) _peakBoost = boost;
      if (torque > _peakTorque) _peakTorque = torque;
      if (_gLat.abs() > _peakLatG) _peakLatG = _gLat.abs();
      if (_gLon.abs() > _peakLonG) _peakLonG = _gLon.abs();
      if (boost > _boostPeakHold) {
        _boostPeakHold = boost;
        _boostPeakTick = _tick;
      }
      if (_tick - _boostPeakTick > 50) _boostPeakHold = boost;

      // ★ HUD 帧日志: 每 30 tick (~1s) 记录关键值到文件
      if (_tick % 30 == 0) {
        final iatVal = _d['uds_iat_b1'] ?? _d['iat'] ?? 0;
        final afrVal = _d['uds_lambda_b1'] ?? _d['afr'] ?? 0;
        BtManager.instance.onLog?.call('HUD',
          't=$_tick RPM=${rpm.toStringAsFixed(0)} SPD=${spd.toStringAsFixed(0)} '
          'BST=${boost.toStringAsFixed(1)} TRQ=${torque.toStringAsFixed(0)} '
          'THR=${throttle.toStringAsFixed(1)} GEAR=$gear '
          'IAT=${iatVal.toStringAsFixed(0)} AFR=${afrVal.toStringAsFixed(1)} '
          'P-BST=${_peakBoost.toStringAsFixed(1)} P-TRQ=${_peakTorque.toStringAsFixed(0)}');
      }

      // ★ 告警事件: 升档/全力全開 触发时记录
      if (_wShift && !_prevShift) {
        BtManager.instance.onLog?.call('EVT', 'UP_SHIFT RPM=${rpm.toStringAsFixed(0)} SPD=${spd.toStringAsFixed(0)} GEAR=$gear');
      }
      if (_wFullThrottle && !_prevFullThrottle) {
        BtManager.instance.onLog?.call('EVT', 'FULL_THROTTLE THR=${throttle.toStringAsFixed(1)} RPM=${rpm.toStringAsFixed(0)} BST=${boost.toStringAsFixed(1)}');
      }
      // 档位变化
      if (gear != _prevGear && gear > 0 && _prevGear > 0) {
        BtManager.instance.onLog?.call('EVT', 'GEAR $_prevGear→$gear RPM=${rpm.toStringAsFixed(0)} SPD=${spd.toStringAsFixed(0)}');
      }
    });
  }

  void _onData(PollSnapshot s) {
    _tick++;
    _interp.pushData(s.values);
    _d.addAll(s.values);
  }

  /// 构建 6 通道显示数据
  List<ChannelDisplay> _buildChannelDisplays() {
    final displays = <ChannelDisplay>[];
    for (final slot in HudSlot.values) {
      final ch = HudChannelStore.get(slot);
      final val = _d[ch.pidId] ?? 0;
      final gaugeCaution = ch.warnDirection == WarnDirection.low
          ? ch.cautionLow : ch.cautionHigh;
      final gaugeDanger = ch.warnDirection == WarnDirection.low
          ? ch.dangerLow : ch.dangerHigh;
      displays.add(ChannelDisplay(
        label: ch.label,
        jpLabel: ch.jpLabel,
        pidId: ch.pidId,
        unit: ch.unit,
        value: val,
        gaugeMax: ch.gaugeMax,
        caution: gaugeCaution,
        danger: gaugeDanger,
        isCaution: ch.isCaution(val),
        isDanger: ch.isDanger(val),
        alertStyle: ch.alertStyle,
        alertTitleJp: ch.alertTitleJp,
        alertTitleEn: ch.alertTitleEn,
      ));
    }
    return displays;
  }

  void _startDemo() {
    if (!_alive) return;
    _can.startDemo(_buildSelectedPids());
    if (_alive && mounted) setState(() {});
  }

  void _startReal() {
    if (!_alive) return;
    // ★ 开始记录全部 RAW 指令 (调试用)
   // BtManager.instance.rawTraceStart();
    _can.start(_buildSelectedPids());
    if (_alive && mounted) setState(() {});
  }

  void _exit() async {
    if (!_alive) return;
    _alive = false;
    _renderTicker.stop();
    OledHelper.instance.restoreBrightness();
    _can.stop();

    // ★ 停止 RAW 追踪, 复制到剪贴板
    // final trace = BtManager.instance.rawTraceStop();
    //if (trace.isNotEmpty) {
     // await Clipboard.setData(ClipboardData(text: trace));
    // }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final wp = widget.wallpaper;
    final hasWp = wp != null && wp.existsSync();

    return Scaffold(
      backgroundColor: hudBg,
      body: GestureDetector(
        onDoubleTap: _exit,
        child: Stack(children: [
          if (hasWp) ...[
            Positioned.fill(child: Image.file(wp, fit: BoxFit.cover,
              key: ValueKey(wp.path), gaplessPlayback: false,
              errorBuilder: (_, __, ___) => Container(color: hudBg))),
            Positioned.fill(child: Container(
              color: Colors.black.withOpacity(widget.darkness))),
          ],
          SafeArea(child: Column(children: [
            _statusRow(),
            Expanded(child: HudPageEva(d: HudData(
              values: _d,
              flashOn: _flashOn,
              tick: _tick,
              boostPeakHold: _boostPeakHold,
              boostPeakTick: _boostPeakTick,
              wShift: _wShift,
              wFullThrottle: _wFullThrottle,
              fullThrottleTicks: _fullThrottleTicks,
              ftExitTick: _ftExitTick,
              ftPeakTick: _ftPeakTick,
              activeAlerts: List.unmodifiable(_activeAlerts),
              displayAlertIndex: _displayAlertIdx,
              multiCrisis: _multiCrisis,
              alertShownTicks: List.unmodifiable(_alertShownTicksList),
              slipping: _slipping,
              gearChangeKey: _gearChangeKey,
              obdGearMode:
                  HudChannelStore.gearSource == GearSource.obdPid,
              peakBoost: _peakBoost,
              peakTorque: _peakTorque,
              peakLatG: _peakLatG,
              peakLonG: _peakLonG,
              rpmMax: HudChannelStore.rpmMax,
              shiftRpm: HudChannelStore.shiftRpm,
              channelDisplays: _buildChannelDisplays(),
            ))),
          ])),
        ]),
      ),
    );
  }

  Widget _statusRow() {
    final modeLabel = 'UDS ME-ECU';
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.black.withOpacity(0.3),
      child: Row(children: [
        Container(width: 10, height: 3, decoration: BoxDecoration(
          color: cCyan, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        const Text('EVA HUD', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: [kFontHud],
          fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 1, color: cDim)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: cCyan.withOpacity(0.08),
            borderRadius: BorderRadius.circular(2)),
          child: Text(modeLabel, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
            fontSize: 6, fontWeight: FontWeight.w800, color: cCyan.withOpacity(0.6)))),
        const Spacer(),
        if (_can.isDemo) Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: cOrange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(2)),
          child: const Text('DEMO', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: [kFontHud],
            fontSize: 6, fontWeight: FontWeight.w800, color: cOrange))),
        Text('${_hz.toStringAsFixed(1)} Hz', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
          fontSize: 7, fontWeight: FontWeight.w700,
          color: _hz >= 3 ? cDim : _hz >= 1.5 ? cOrange : cLava)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _exit,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: cLava.withOpacity(0.15),
              borderRadius: BorderRadius.circular(2)),
            child: const Text('EXIT', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: [kFontHud],
              fontSize: 6, fontWeight: FontWeight.w800, color: cLava)))),
      ]),
    );
  }
}