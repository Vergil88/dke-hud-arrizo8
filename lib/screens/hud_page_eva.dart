import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/hud_channel_config.dart';
import 'hud_shared.dart';
import 'hud_skin.dart';
import 'hud_sfx.dart';

// ════════════════════════════════════════════════════════════════
// hud_page_eva.dart — EVA NERV 戦闘座舱 v4 (重構版)
// ════════════════════════════════════════════════════════════════
// ★ 警報: 全部由 HudData.activeAlerts 驱动, 无硬编码通道
// ★ 音效: 全部在编排器 (eva_hud_screen) 中处理, 皮肤层零音频
// ════════════════════════════════════════════════════════════════

const _amber  = Color(0xFFFF8800);
const _yellow = Color(0xFFFFDD00);
const _red    = Color(0xFFFF1100);
const _dimAmb = Color(0xFF553300);
const _hazard = Color(0xFFCCBB00);

const _hex = 'A7 3F 0B E2 91 D4 C8 55 1A 7E B0 F3 6C 2D 89 04 E7 5B 3A C1 D6 48 9F 72 1E A5 B8 0D 63 F4 2C 77 9A';

// ── 连接音效 (仅此一个, 无警报音效) ────────────
class _EvaCan1 {
  _EvaCan1._();
  static bool _played = false;
  static void tryPlay(int tick) {
    if (_played || tick != 5) return;
    _played = true;
    HudSfx.instance.playCan1();
  }
  static void reset() { _played = false; }
}

class HudPageEva extends HudSkin {
  const HudPageEva({super.key, required super.d});
  double _v(String id) => d.v(id);

  bool get _em => d.isEmergencyMode;
  bool get _critical => d.hasAlert;
  bool get _slowFlash => d.tick % 4 < 2;
  bool get _fastFlash => d.tick % 2 == 0;  // ★ 超高速闪烁 (全力全開专用)
  Color get _mc => _em ? _red : _amber;

  /// 最高优先级活跃警报
  ActiveAlert? get _top => d.topAlert;

  @override
  Widget build(BuildContext context) {
    _EvaCan1.tryPlay(d.tick);
    return Stack(children: [
      // Z-0: 六角网格
      Positioned.fill(child: RepaintBoundary(
        child: CustomPaint(painter: _HexGridPainter(mc: _mc)))),

      // Z-1: 全部数据
      Column(children: [
        _topBanner(),
        _hexStream(),
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 130, child: _leftWing()),
          Container(width: 1, color: _mc.withOpacity(0.1)),
          Expanded(child: _centerMega()),
          Container(width: 1, color: _mc.withOpacity(0.1)),
          SizedBox(width: 155, child: _rightWing()),
        ])),
        _bottomTriple(),
      ]),

      // Z-2: CRT
      Positioned.fill(child: IgnorePointer(
        child: RepaintBoundary(child: CustomPaint(painter: _CrtPainter())))),

      // Z-3: 強制升档 (独立于通道警报)
      if (d.wShift && d.flashOn)
        Positioned.fill(child: IgnorePointer(child: Container(
          color: _red.withOpacity(0.18),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            FractionallySizedBox(widthFactor: 0.85,
              child: FittedBox(fit: BoxFit.fitWidth,
                child: Text('強制升档', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                  fontWeight: FontWeight.w900, height: 1.1,
                  color: Colors.white.withOpacity(0.9),
                  shadows: [
                    Shadow(color: _red, blurRadius: 60),
                    Shadow(color: _red.withOpacity(0.8), blurRadius: 120),
                    Shadow(color: _amber.withOpacity(0.4), blurRadius: 200),
                  ])))),
            const SizedBox(height: 4),
            Text('FORCED UPSHIFT // 回転数限界超過', style: TextStyle(
              fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 11,
              fontWeight: FontWeight.w800, letterSpacing: 6,
              color: _red.withOpacity(0.7))),
          ])))),

      // ★ Z-4: 多重警報発令 — 3+警报复合危机叠层
      if (d.multiCrisis) ..._multiCrisisOverlay(),

      // ★ Z-5: 通道警报叠层 (轮播驱动)
      if (d.displayedAlert != null) ..._buildAlertOverlay(d.displayedAlert!),

      // ★ Z-5.5: 警报计数指示器 (2+警报时显示)
      if (d.activeAlerts.length >= 2) _alertCountIndicator(),

      // ★ Z-6: 全力全開 — 最高级别, 覆盖一切 (含退出動画)
      if (d.wFullThrottle || d.ftExitTick > 0) ..._fullThrottleOverlay(),
    ]);
  }

  // ════════════════════════════════════════════════════
  // ★ Z-6: 全力全開 — Phase 駆動アニメーション v3
  // ════════════════════════════════════════════════════
  // ★ 改善点:
  //   - 抖動 (shake) 全廃: 全フェーズで震動なし
  //   - パーティクル流: 滑らかな放射光線 (EV ローンチ風)
  //   - HUD 遮蔽: 黒背景で HUD データを暗転、EVA 六角格子は薄く残す
  //   - 退出動画: 解除時に逆再生で素早く縮小フェードアウト
  //   - 65% 到達後: サイズ固定、背景エフェクトのみ持続
  // ════════════════════════════════════════════════════

  static const _ftGold   = Color(0xFFFFB300);
  static const _ftWhite  = Color(0xFFFFF8E1);
  static const _ftAmber  = Color(0xFFFF8F00);

  /// smoothstep
  static double _ss(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  /// ★ 退出中か否か
  bool get _ftExiting => d.ftExitTick > 0 && !d.wFullThrottle;

  /// ★ Phase ルーター
  List<Widget> _fullThrottleOverlay() {
    // ── 退出動画 ──
    if (_ftExiting) return _ftExit();

    final ftTick = d.fullThrottleTicks;
    // Phase 0: 原版ゴールドバースト (0-1.5s)
    if (ftTick <= 44) return _ftPhase0();
    final pt = ftTick - 45;
    if (pt < 30) return _ftPhase1(pt);   // 1.0s 圧抑
    return _ftPhase2(pt - 30);            // 3.0s 拡大 → 65% 固定保持
  }

  /// ★ HUD 暗転背景 — 黒で HUD データを遮蔽、六角格子を薄く残す
  Widget _ftDimBg(double opacity) => Positioned.fill(
    child: IgnorePointer(child: Container(color: Colors.black.withOpacity(opacity))));

  /// ★ 速度テキスト — HUD 統一フォント, 整数, 中央配置
  Widget _ftSpeedWidget(double widthFactor, Color color, double glow) {
    final spd = d.v('speed').round().clamp(0, 999);
    return Positioned.fill(child: IgnorePointer(child: Center(
      child: FractionallySizedBox(
        widthFactor: widthFactor.clamp(0.01, 1.0),
        child: FittedBox(fit: BoxFit.fitWidth,
          child: Text('$spd',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: const [kFontHud],
              fontWeight: FontWeight.w900,
              height: 1.0,
              color: color,
              shadows: glow > 0 ? [
                Shadow(color: color, blurRadius: glow),
                Shadow(color: color.withOpacity(0.35), blurRadius: glow * 2.5),
              ] : null)))))));
  }

  /// ── Phase 0: 原版ゴールドバースト ─────────────────
  List<Widget> _ftPhase0() {
    final hi = _fastFlash;
    return [
      _ftDimBg(0.75),
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 1.0 : 0.6,
          duration: const Duration(milliseconds: 60),
          child: Container(
            decoration: BoxDecoration(gradient: RadialGradient(
              center: Alignment.center, radius: 1.5,
              stops: const [0.0, 0.15, 0.4, 0.7, 1.0],
              colors: [
                _ftWhite.withOpacity(hi ? 0.20 : 0.05),
                _ftGold.withOpacity(hi ? 0.15 : 0.04),
                _ftAmber.withOpacity(hi ? 0.08 : 0.02),
                _ftGold.withOpacity(hi ? 0.03 : 0.01),
                Colors.transparent,
              ])))))),
      Positioned(top: 0, left: 0, right: 0, height: 24,
        child: RepaintBoundary(child: CustomPaint(
          painter: _ThrottleBarPainter(tick: d.tick, flash: hi, color: _ftGold)))),
      Positioned(bottom: 0, left: 0, right: 0, height: 24,
        child: RepaintBoundary(child: CustomPaint(
          painter: _ThrottleBarPainter(tick: d.tick, flash: hi, color: _ftGold)))),
      Positioned(top: 0, left: 0, bottom: 0, width: 6,
        child: Container(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [_ftGold.withOpacity(hi ? 0.5 : 0.1), _ftWhite.withOpacity(hi ? 0.7 : 0.15), _ftGold.withOpacity(hi ? 0.5 : 0.1)])))),
      Positioned(top: 0, right: 0, bottom: 0, width: 6,
        child: Container(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [_ftGold.withOpacity(hi ? 0.5 : 0.1), _ftWhite.withOpacity(hi ? 0.7 : 0.15), _ftGold.withOpacity(hi ? 0.5 : 0.1)])))),
      Positioned.fill(child: IgnorePointer(child: Column(
        mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedOpacity(opacity: hi ? 1.0 : 0.0, duration: const Duration(milliseconds: 40),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(border: Border.all(color: _ftGold.withOpacity(0.5), width: 1), color: Colors.black.withOpacity(0.6)),
              child: Text('S² 機関 臨界出力 // LIMITER RELEASED',
                style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                  fontWeight: FontWeight.w900, letterSpacing: 3, color: _ftGold.withOpacity(0.7))))),
          const SizedBox(height: 8),
          FractionallySizedBox(widthFactor: 0.92,
            child: FittedBox(fit: BoxFit.fitWidth,
              child: Text('全力全開', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                fontWeight: FontWeight.w900, height: 1.0, color: hi ? Colors.white : _ftGold,
                shadows: [Shadow(color: _ftGold, blurRadius: 50), Shadow(color: _ftGold.withOpacity(0.8), blurRadius: 100),
                  Shadow(color: _ftAmber.withOpacity(0.5), blurRadius: 180), Shadow(color: _ftWhite.withOpacity(0.3), blurRadius: 250)])))),
          const SizedBox(height: 4),
          Text('FULL THROTTLE // 最大出力解放', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
            fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 6, color: _ftGold.withOpacity(hi ? 0.9 : 0.5))),
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _ftChip('THROTTLE', '100%', _ftGold, hi), const SizedBox(width: 10),
            _ftChip('OUTPUT', 'MAX', _ftAmber, hi), const SizedBox(width: 10),
            _ftChip('SYNC', '${(85 + d.tick % 15)}%', _ftGold, hi),
          ]),
        ]))),
    ];
  }

  /// ── Phase 1: 圧抑 — 暗転 + 微小速度 ──────────────
  List<Widget> _ftPhase1(int pt) {
    final p = _ss(pt / 29.0);
    final wf = 0.06 + p * 0.04;
    final glw = 8.0 + p * 15.0;
    final dimOp = 0.75 + p * 0.07; // 暗転維持
    return [
      _ftDimBg(dimOp),
      Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _CrtPainter()))),
      _ftSpeedWidget(wf, _ftGold, glw),
    ];
  }

  /// ── Phase 2: 爆発 → 65% 固定保持 ──────────────────
  List<Widget> _ftPhase2(int pt) {
    final growP = _ss((pt / 89.0).clamp(0.0, 1.0));
    final hold = pt >= 90;

    // widthFactor: 0.10 → 0.65 then lock
    final wf = 0.10 + growP * 0.55;

    // 流線強度
    final lineI = hold ? 1.0 : (0.3 + growP * 0.7);

    // 色: 後半は白フラッシュ交互
    final hi = (d.tick % 4) < 2;
    final color = (growP > 0.6 && hi) ? _ftWhite : _ftGold;

    final glw = hold ? 60.0 : (20.0 + growP * 40.0);

    return [
      // 暗転背景
      _ftDimBg(0.82),
      // ★ 滑らかな放射流線
      Positioned.fill(child: RepaintBoundary(
        child: CustomPaint(painter: _FtFlowLinePainter(
          tick: d.tick, intensity: lineI)))),
      // 走査線
      Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _CrtPainter()))),
      // 速度テキスト (震動なし)
      _ftSpeedWidget(wf, color, glw),
    ];
  }

  /// ── 退出動画: 逆再生で縮小フェードアウト ─────────
  List<Widget> _ftExit() {
    final exitP = _ss(d.ftExitTick / 20.0); // 0→1 over 20 ticks

    // ピーク時の widthFactor を計算
    final peakTick = d.ftPeakTick;
    final peakPt = peakTick > 45 ? peakTick - 45 : 0;
    double peakWf;
    if (peakPt < 30) {
      // Phase 1 中に解除
      final p1 = _ss(peakPt / 29.0);
      peakWf = 0.06 + p1 * 0.04;
    } else {
      // Phase 2 中に解除
      final p2 = _ss(((peakPt - 30) / 89.0).clamp(0.0, 1.0));
      peakWf = 0.10 + p2 * 0.55;
    }

    // 逆再生: peakWf → 0, opacity → 0
    final wf = peakWf * (1.0 - exitP);
    final alpha = (1.0 - exitP).clamp(0.0, 1.0);
    final dimOp = 0.82 * (1.0 - exitP); // 暗転も解除
    final lineI = (1.0 - exitP).clamp(0.0, 1.0);

    return [
      if (dimOp > 0.01) _ftDimBg(dimOp),
      if (lineI > 0.01)
        Positioned.fill(child: Opacity(
          opacity: alpha,
          child: RepaintBoundary(
            child: CustomPaint(painter: _FtFlowLinePainter(
              tick: d.tick, intensity: lineI))))),
      if (wf > 0.01)
        _ftSpeedWidget(wf, _ftGold.withOpacity(alpha), 30.0 * alpha),
    ];
  }

  Widget _ftChip(String label, String value, Color c, bool hi) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      border: Border.all(color: c.withOpacity(hi ? 0.5 : 0.15), width: 1),
      color: Colors.black.withOpacity(0.5)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label:', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 7,
        fontWeight: FontWeight.w700, color: c.withOpacity(0.5))),
      const SizedBox(width: 4),
      Text(value, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 9,
        fontWeight: FontWeight.w900, color: hi ? Colors.white : c)),
    ]));

  // ════════════════════════════════════════════════════
  // ★ Z-4: 多重警報発令 — 3+警报时的复合危机底层
  // ════════════════════════════════════════════════════

  List<Widget> _multiCrisisOverlay() {
    const crisisRed  = Color(0xFFFF0033);
    const crisisBlk  = Color(0xFF1A0005);
    final phase = (d.tick ~/ 8) % 3;  // 3相循环: 黑→红→暗红
    final opacity = switch (phase) {
      0 => 0.35,
      1 => 0.15,
      _ => 0.25,
    };

    return [
      // L-0: 全屏脉动底色 — 黑红交替
      Positioned.fill(child: IgnorePointer(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: crisisRed.withOpacity(opacity * 0.5)))),

      // L-1: 上下警告条 — 加粗加亮
      Positioned(top: 0, left: 0, right: 0, height: 24,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: _slowFlash)))),
      Positioned(bottom: 0, left: 0, right: 0, height: 24,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: _slowFlash)))),

      // L-2: 多重警報标签 — 居中上方
      Positioned(
        top: 26, left: 0, right: 0,
        child: IgnorePointer(child: Center(child: AnimatedOpacity(
          opacity: _slowFlash ? 1.0 : 0.4,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: crisisBlk.withOpacity(0.9),
              border: Border.all(color: crisisRed.withOpacity(0.7), width: 2),
              boxShadow: [BoxShadow(color: crisisRed.withOpacity(0.3), blurRadius: 20)]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('多重警報発令', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 4,
                color: _slowFlash ? Colors.white : crisisRed,
                shadows: [Shadow(color: crisisRed, blurRadius: 12)])),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: crisisRed.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(3)),
                child: Text('×${d.activeAlerts.length}', style: TextStyle(
                  fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 12,
                  fontWeight: FontWeight.w900, color: Colors.white))),
            ])))))),

      // L-3: 底部全警报列表 — 小字横排
      Positioned(
        bottom: 26, left: 20, right: 20,
        child: IgnorePointer(child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: d.activeAlerts.asMap().entries.map((e) {
            final idx = e.key;
            final a = e.value;
            final isDisplayed = idx == d.displayAlertIndex;
            final alertC = switch (a.style) {
              AlertStyle.emergency => _red,
              AlertStyle.fuelCritical => const Color(0xFFFF0050),
              AlertStyle.afrAnomaly => const Color(0xFF76FF03),
              AlertStyle.overboost => const Color(0xFF00E5FF),
              AlertStyle.overheat => const Color(0xFFFF6600),
              AlertStyle.generic => _amber,
              AlertStyle.none => _amber,
            };
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: isDisplayed ? alertC.withOpacity(0.2) : Colors.black.withOpacity(0.6),
                  border: Border.all(
                    color: isDisplayed ? alertC.withOpacity(0.8) : alertC.withOpacity(0.2),
                    width: isDisplayed ? 2 : 1),
                  borderRadius: BorderRadius.circular(3)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(a.titleJp, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                    fontSize: isDisplayed ? 9 : 7, fontWeight: FontWeight.w900,
                    color: isDisplayed ? Colors.white : alertC.withOpacity(0.6))),
                  Text(a.titleEn, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                    fontSize: 5, fontWeight: FontWeight.w700,
                    color: alertC.withOpacity(isDisplayed ? 0.6 : 0.3))),
                ])));
          }).toList()))),
    ];
  }

  // ════════════════════════════════════════════════════
  // ★ Z-5.5: 警报计数指示器 (2+警报, 非 multiCrisis 时)
  // ════════════════════════════════════════════════════

  Widget _alertCountIndicator() {
    if (d.multiCrisis) return const SizedBox.shrink(); // multiCrisis 已有底部列表
    return Positioned(
      top: 20, right: 8,
      child: IgnorePointer(child: AnimatedOpacity(
        opacity: _slowFlash ? 1.0 : 0.5,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            border: Border.all(color: _red.withOpacity(0.5), width: 1),
            borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('ALERT', style: _ts(7, _red.withOpacity(0.7), w: FontWeight.w800)),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: _red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2)),
              child: Text('${d.activeAlerts.length}',
                style: _ts(9, Colors.white, w: FontWeight.w900))),
            const SizedBox(width: 4),
            Text('${d.displayAlertIndex + 1}/${d.activeAlerts.length}',
              style: _ts(6, _red.withOpacity(0.4), w: FontWeight.w700)),
          ])))));
  }

  // ════════════════════════════════════════════════════
  // ★ 警报叠层构建器 — 按 AlertStyle 分派
  // ════════════════════════════════════════════════════

  List<Widget> _buildAlertOverlay(ActiveAlert alert) {
    switch (alert.style) {
      case AlertStyle.emergency:
        return _emergencyOverlay(alert);
      case AlertStyle.overheat:
        return _overheatOverlay(alert);
      case AlertStyle.overboost:
        return _overboostOverlay(alert);
      case AlertStyle.fuelCritical:
        return _fuelCriticalOverlay(alert);
      case AlertStyle.afrAnomaly:
        return _afrAnomalyOverlay(alert);
      case AlertStyle.generic:
        return _genericOverlay(alert);
      case AlertStyle.none:
        return [];
    }
  }

  /// 非常事態 — 黑帧慢闪 + 危险条纹
  List<Widget> _emergencyOverlay(ActiveAlert alert) => [
    // 危险条纹
    Positioned(top: 0, left: 0, right: 0, height: 20,
      child: RepaintBoundary(child: CustomPaint(painter: _HazardPainter(flash: _slowFlash)))),
    Positioned(bottom: 0, left: 0, right: 0, height: 20,
      child: RepaintBoundary(child: CustomPaint(painter: _HazardPainter(flash: _slowFlash)))),
    // 全屏叠层
    Positioned.fill(child: IgnorePointer(
      child: AnimatedOpacity(
        opacity: _slowFlash ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          color: _red.withOpacity(_slowFlash ? 0.2 : 0),
          child: Center(child: FractionallySizedBox(
            widthFactor: 0.9, heightFactor: 0.75,
            child: FittedBox(fit: BoxFit.contain,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: _red, width: 5),
                    color: Colors.black.withOpacity(0.8)),
                  child: Text(alert.titleJp.isNotEmpty ? alert.titleJp : '非常事態',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                      fontWeight: FontWeight.w900,
                      color: _slowFlash ? Colors.white : _red,
                      shadows: [
                        Shadow(color: _red, blurRadius: 50),
                        Shadow(color: _red.withOpacity(0.6), blurRadius: 120),
                      ]))),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
                  color: Colors.black.withOpacity(0.7),
                  child: Text(alert.titleEn.isNotEmpty ? alert.titleEn : 'EMERGENCY',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                      fontWeight: FontWeight.w900, letterSpacing: 14, color: _red))),
                const SizedBox(height: 8),
                Text('${_slotLabel(alert)} DETECTED // 異常検出', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                  fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 4, color: _red)),
                const SizedBox(height: 3),
                Text('CODE: ${100 + d.tick % 200}.', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                  fontSize: 10, fontWeight: FontWeight.w700, color: _red.withOpacity(0.45))),
              ])))))))),
  ];

  /// 冷却過熱 — 热浪渐变 + 大字数值
  List<Widget> _overheatOverlay(ActiveAlert alert) => [
    Positioned.fill(child: IgnorePointer(
      child: AnimatedOpacity(
        opacity: _slowFlash ? 1.0 : 0.6,
        duration: const Duration(milliseconds: 200),
        child: Stack(children: [
          Positioned.fill(child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              stops: const [0.0, 0.25, 0.5, 1.0],
              colors: [
                _red.withOpacity(_slowFlash ? 0.35 : 0.15),
                const Color(0xFFFF4400).withOpacity(_slowFlash ? 0.2 : 0.08),
                _amber.withOpacity(_slowFlash ? 0.08 : 0.02),
                Colors.transparent,
              ])))),
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFFF4400), width: 3),
                color: Colors.black.withOpacity(0.7)),
              child: Text(alert.titleJp.isNotEmpty ? alert.titleJp : '冷却過熱',
                style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                  fontSize: 30, fontWeight: FontWeight.w900,
                  color: _slowFlash ? Colors.white : const Color(0xFFFF4400),
                  shadows: [
                    Shadow(color: const Color(0xFFFF4400), blurRadius: 40),
                    Shadow(color: _amber.withOpacity(0.5), blurRadius: 80),
                  ]))),
            const SizedBox(height: 8),
            FractionallySizedBox(widthFactor: 0.5,
              child: FittedBox(fit: BoxFit.fitWidth,
                child: Text('${alert.value.round().toString().padLeft(3)}${alert.unit}',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                    fontWeight: FontWeight.w900, height: 1.0,
                    color: Colors.white.withOpacity(0.9),
                    shadows: [
                      Shadow(color: _red, blurRadius: 40),
                      Shadow(color: const Color(0xFFFF4400).withOpacity(0.6), blurRadius: 100),
                    ])))),
            const SizedBox(height: 4),
            Text('${_slotLabel(alert)} WARNING // 臨界超過', style: TextStyle(
              fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
              fontWeight: FontWeight.w800, letterSpacing: 3,
              color: const Color(0xFFFF4400).withOpacity(0.7))),
            Text('REDUCE LOAD IMMEDIATELY', style: TextStyle(
              fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
              fontWeight: FontWeight.w700, letterSpacing: 2,
              color: _amber.withOpacity(0.5))),
          ])),
        ])))),
  ];

  /// ★ 増圧限界突破 — A.T.フィールド出力超過 / 能量脉冲
  List<Widget> _overboostOverlay(ActiveAlert alert) {
    const cyan    = Color(0xFF00E5FF);
    const teal    = Color(0xFF00BCD4);
    const iceBlue = Color(0xFF80DEEA);
    final pulseHi = _slowFlash;

    return [
      // L-1: 全屏能量脉冲渐变 (中心向外辐射)
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: pulseHi ? 0.9 : 0.5,
          duration: const Duration(milliseconds: 180),
          child: Container(
            decoration: BoxDecoration(gradient: RadialGradient(
              center: Alignment.center, radius: 1.2,
              stops: const [0.0, 0.3, 0.6, 1.0],
              colors: [
                cyan.withOpacity(pulseHi ? 0.18 : 0.06),
                teal.withOpacity(pulseHi ? 0.10 : 0.03),
                cyan.withOpacity(pulseHi ? 0.04 : 0.01),
                Colors.transparent,
              ])))))),

      // L-2: 上下扫描线装饰 (几何能量条, 非火焰)
      Positioned(top: 0, left: 0, right: 0, height: 16,
        child: RepaintBoundary(child: CustomPaint(
          painter: _BoostScanPainter(flash: pulseHi, color: cyan)))),
      Positioned(bottom: 0, left: 0, right: 0, height: 16,
        child: RepaintBoundary(child: CustomPaint(
          painter: _BoostScanPainter(flash: pulseHi, color: cyan)))),

      // L-3: 中央警报面板
      Positioned.fill(child: IgnorePointer(
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── 外框: 双线军事风格 ──
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              border: Border.all(color: cyan.withOpacity(pulseHi ? 0.6 : 0.2), width: 2)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: cyan.withOpacity(pulseHi ? 0.4 : 0.15), width: 1),
                color: Colors.black.withOpacity(0.85)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // 系統警告标签
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  color: cyan.withOpacity(pulseHi ? 0.15 : 0.05),
                  child: Text('MAGI SYSTEM WARNING', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                    fontSize: 7, fontWeight: FontWeight.w800, letterSpacing: 4,
                    color: teal.withOpacity(0.6)))),
                const SizedBox(height: 10),
                // ★ 主标题 — 増圧限界
                Text(alert.titleJp.isNotEmpty ? alert.titleJp : '増圧限界',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 32,
                    fontWeight: FontWeight.w900, height: 1.0,
                    color: pulseHi ? Colors.white : cyan,
                    shadows: [
                      Shadow(color: cyan, blurRadius: 30),
                      Shadow(color: cyan.withOpacity(0.5), blurRadius: 60),
                      Shadow(color: teal.withOpacity(0.3), blurRadius: 100),
                    ])),
                const SizedBox(height: 4),
                // 英文副标题
                Text(alert.titleEn.isNotEmpty ? alert.titleEn : 'OVERBOOST',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 12,
                    fontWeight: FontWeight.w900, letterSpacing: 8,
                    color: cyan.withOpacity(0.7))),
                const SizedBox(height: 12),
                // ★ 巨大数值
                Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(alert.value.toStringAsFixed(alert.value > 100 ? 0 : 1),
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 48,
                      fontWeight: FontWeight.w900, height: 0.9,
                      color: Colors.white.withOpacity(pulseHi ? 1.0 : 0.7),
                      shadows: [
                        Shadow(color: cyan, blurRadius: 20),
                        Shadow(color: cyan.withOpacity(0.4), blurRadius: 50),
                      ])),
                  Padding(padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Text(alert.unit,
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 14,
                        fontWeight: FontWeight.w800, color: iceBlue.withOpacity(0.6)))),
                ]),
                const SizedBox(height: 10),
                // 分隔线
                Container(width: 180, height: 1, color: cyan.withOpacity(pulseHi ? 0.3 : 0.1)),
                const SizedBox(height: 8),
                // 底部状态行
                Text('${_slotLabel(alert)} LIMIT EXCEEDED // 出力限界突破',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                    fontWeight: FontWeight.w800, letterSpacing: 2,
                    color: cyan.withOpacity(0.5))),
                const SizedBox(height: 3),
                Text('A.T.FIELD 圧力飽和 // REDUCE OUTPUT IMMEDIATELY',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 7,
                    fontWeight: FontWeight.w700, letterSpacing: 1,
                    color: teal.withOpacity(0.35))),
                const SizedBox(height: 3),
                Text('CODE: B-${(200 + d.tick % 300).toString()}.${d.tick % 10}',
                  style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 6,
                    fontWeight: FontWeight.w700, color: cyan.withOpacity(0.2))),
              ]))),
        ])))),
    ];
  }

  /// ★ 燃圧喪失 — 生命線断絶 / 燃料系統崩壊 (emergency 同級)
  List<Widget> _fuelCriticalOverlay(ActiveAlert alert) {
    const magenta = Color(0xFFFF0050);
    const violet  = Color(0xFF9C27B0);
    const pale    = Color(0xFFFF80AB);
    final hi = _slowFlash;

    return [
      // L-0: 上下危機条 — 紫紅交替脈動
      Positioned(top: 0, left: 0, right: 0, height: 20,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: hi)))),
      Positioned(bottom: 0, left: 0, right: 0, height: 20,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: hi)))),

      // L-1: 全屏 — 上方向下侵蝕的枯渇渐变 (燃料流失感)
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 120),
          child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              stops: const [0.0, 0.3, 0.55, 0.75, 1.0],
              colors: [
                magenta.withOpacity(hi ? 0.25 : 0),
                violet.withOpacity(hi ? 0.15 : 0),
                magenta.withOpacity(hi ? 0.08 : 0),
                violet.withOpacity(hi ? 0.04 : 0),
                Colors.transparent,
              ])))))),

      // L-2: 中央警報面板
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 120),
          child: Container(
            color: magenta.withOpacity(hi ? 0.12 : 0),
            child: Center(child: FractionallySizedBox(
              widthFactor: 0.88, heightFactor: 0.72,
              child: FittedBox(fit: BoxFit.contain,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // ── 系統崩壊标签 ──
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    color: violet.withOpacity(hi ? 0.3 : 0.05),
                    child: Text('MAGI ALERT // 生命維持系統', style: TextStyle(
                      fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                      fontWeight: FontWeight.w900, letterSpacing: 4,
                      color: pale.withOpacity(0.6)))),
                  const SizedBox(height: 10),
                  // ★ 主框体 — 双线军事框 + 核心文字
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      border: Border.all(color: magenta.withOpacity(hi ? 0.7 : 0.2), width: 4)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: magenta.withOpacity(hi ? 0.4 : 0.1), width: 1),
                        color: Colors.black.withOpacity(0.85)),
                      child: Text(
                        alert.titleJp.isNotEmpty ? alert.titleJp : '燃圧喪失',
                        style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                          fontWeight: FontWeight.w900,
                          color: hi ? Colors.white : magenta,
                          shadows: [
                            Shadow(color: magenta, blurRadius: 40),
                            Shadow(color: violet.withOpacity(0.6), blurRadius: 80),
                            Shadow(color: magenta.withOpacity(0.4), blurRadius: 120),
                          ])))),
                  const SizedBox(height: 10),
                  // 英文副标题
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                    color: Colors.black.withOpacity(0.7),
                    child: Text(
                      alert.titleEn.isNotEmpty ? alert.titleEn : 'FUEL CRITICAL',
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                        fontWeight: FontWeight.w900, letterSpacing: 12,
                        color: magenta))),
                  const SizedBox(height: 12),
                  // ★ 燃圧数値 — 巨大 + 枯渇感
                  Row(mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('▼', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: magenta.withOpacity(hi ? 0.8 : 0.3))),
                    const SizedBox(width: 4),
                    Text(alert.value.toStringAsFixed(1),
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 36,
                        fontWeight: FontWeight.w900, height: 0.9,
                        color: Colors.white.withOpacity(hi ? 1.0 : 0.5),
                        shadows: [
                          Shadow(color: magenta, blurRadius: 30),
                          Shadow(color: violet.withOpacity(0.5), blurRadius: 60),
                        ])),
                    Padding(padding: const EdgeInsets.only(bottom: 4, left: 4),
                      child: Text(alert.unit,
                        style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: pale.withOpacity(0.5)))),
                  ]),
                  const SizedBox(height: 10),
                  // ★ 枯渇ゲージ — 残量可视化
                  _fuelDrainBar(alert, magenta, violet, hi),
                  const SizedBox(height: 10),
                  // 底部状态
                  Text('${_slotLabel(alert)} SUPPLY FAILURE // 生命線断絶',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 13,
                      fontWeight: FontWeight.w800, letterSpacing: 3,
                      color: magenta.withOpacity(0.6))),
                  const SizedBox(height: 4),
                  Text('内燃機関 燃料系統崩壊 // ENGINE SHUTDOWN IMMINENT',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5,
                      color: violet.withOpacity(0.45))),
                  const SizedBox(height: 3),
                  Text('CODE: F-${(400 + d.tick % 200)}.${d.tick % 10}',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: magenta.withOpacity(0.2))),
                ]))))),
        ))),
    ];
  }

  /// 燃料枯渇ゲージ — 残量バー
  Widget _fuelDrainBar(ActiveAlert alert, Color magenta, Color violet, bool hi) {
    // 計算残量比 (dangerLow を基準)
    final ch = d.channelDisplays.firstWhere(
      (c) => c.pidId == d.channelDisplays[alert.slot.index].pidId,
      orElse: () => d.channelDisplays[alert.slot.index]);
    final pct = (alert.value / ch.gaugeMax).clamp(0.0, 1.0);
    const segs = 20;
    final lit = (pct * segs).round().clamp(0, segs);

    return SizedBox(width: 260, height: 16,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('E ', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
          fontWeight: FontWeight.w900, color: magenta.withOpacity(0.7))),
        Expanded(child: Row(children: List.generate(segs, (i) {
          final on = i < lit;
          final c = i < 4 ? magenta : (i < 10 ? violet : magenta.withOpacity(0.3));
          return Expanded(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            color: on
                ? (hi ? c.withOpacity(0.8) : c.withOpacity(0.3))
                : c.withOpacity(0.05)));
        }))),
        Text(' F', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
          fontWeight: FontWeight.w900, color: magenta.withOpacity(0.25))),
      ]));
  }

  /// ★ 空燃比異常 — 混合気崩壊 / AFR 逸脱 (knock 同級構造)
  List<Widget> _afrAnomalyOverlay(ActiveAlert alert) {
    const toxGreen = Color(0xFF76FF03);
    const acidLime = Color(0xFFAEEA00);
    const dark     = Color(0xFF33691E);
    final hi = _slowFlash;
    // AFR 偏向判定: AFR > 14.7 过稀 (LEAN), AFR < 14.7 过浓 (RICH), 理想 AFR = 14.7
    final isLean = alert.value > 15.4;
    final deviationLabel = isLean ? 'LEAN' : 'RICH';
    final deviationJp    = isLean ? '希薄' : '過濃';

    return [
      // L-0: 上下危険条 — 復用 HazardPainter (knock 同様)
      Positioned(top: 0, left: 0, right: 0, height: 20,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: hi)))),
      Positioned(bottom: 0, left: 0, right: 0, height: 20,
        child: RepaintBoundary(child: CustomPaint(
          painter: _HazardPainter(flash: hi)))),

      // L-1: 全屏黒帯閃光 (knock 同様 — 黒背景を慢速フラッシュ)
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 120),
          child: Container(color: Colors.black.withOpacity(hi ? 0.6 : 0))))),

      // L-2: 毒性グリーン汚染渐变
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 0.9 : 0.4,
          duration: const Duration(milliseconds: 150),
          child: Container(
            decoration: BoxDecoration(gradient: RadialGradient(
              center: Alignment.center, radius: 1.3,
              stops: const [0.0, 0.25, 0.55, 1.0],
              colors: [
                toxGreen.withOpacity(hi ? 0.15 : 0.04),
                acidLime.withOpacity(hi ? 0.08 : 0.02),
                toxGreen.withOpacity(hi ? 0.03 : 0.01),
                Colors.transparent,
              ])))))),

      // L-3: 中央警報面板 (knock 同級 — 双線軍事框)
      Positioned.fill(child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: hi ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 120),
          child: Container(
            color: toxGreen.withOpacity(hi ? 0.06 : 0),
            child: Center(child: FractionallySizedBox(
              widthFactor: 0.88, heightFactor: 0.72,
              child: FittedBox(fit: BoxFit.contain,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // ── 系統異常标签 ──
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    color: dark.withOpacity(hi ? 0.5 : 0.1),
                    child: Text('MAGI ALERT // 混合気異常検出', style: TextStyle(
                      fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                      fontWeight: FontWeight.w900, letterSpacing: 4,
                      color: acidLime.withOpacity(0.6)))),
                  const SizedBox(height: 10),
                  // ★ 主框体 — 双線 + 核心文字
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      border: Border.all(color: toxGreen.withOpacity(hi ? 0.7 : 0.2), width: 4)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: toxGreen.withOpacity(hi ? 0.4 : 0.1), width: 1),
                        color: Colors.black.withOpacity(0.85)),
                      child: Text(
                        alert.titleJp.isNotEmpty ? alert.titleJp : '混合気崩壊',
                        style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                          fontWeight: FontWeight.w900,
                          color: hi ? Colors.white : toxGreen,
                          shadows: [
                            Shadow(color: toxGreen, blurRadius: 40),
                            Shadow(color: acidLime.withOpacity(0.5), blurRadius: 80),
                            Shadow(color: toxGreen.withOpacity(0.3), blurRadius: 120),
                          ])))),
                  const SizedBox(height: 10),
                  // 英文副标题
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                    color: Colors.black.withOpacity(0.7),
                    child: Text(
                      alert.titleEn.isNotEmpty ? alert.titleEn : 'AFR ANOMALY',
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                        fontWeight: FontWeight.w900, letterSpacing: 12,
                        color: toxGreen))),
                  const SizedBox(height: 12),
                  // ★ RICH / LEAN 偏向指示
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    _afrDevChip('LEAN //希薄', !isLean, toxGreen, acidLime),
                    const SizedBox(width: 6),
                    Container(width: 2, height: 22, color: toxGreen.withOpacity(0.3)),
                    const SizedBox(width: 6),
                    _afrDevChip('RICH //過濃', isLean, toxGreen, acidLime),
                  ]),
                  const SizedBox(height: 10),
                  // ★ AFR 数値
                  Row(mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('$deviationLabel ',
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: toxGreen.withOpacity(hi ? 0.8 : 0.3))),
                    Text(alert.value.toStringAsFixed(alert.value > 2 ? 1 : 3),
                      style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 36,
                        fontWeight: FontWeight.w900, height: 0.9,
                       
                        color: Colors.white.withOpacity(hi ? 1.0 : 0.5),
                        shadows: [
                          Shadow(color: toxGreen, blurRadius: 30),
                          Shadow(color: acidLime.withOpacity(0.4), blurRadius: 60),
                        ])),
                    Padding(padding: const EdgeInsets.only(bottom: 4, left: 4),
                      child: Text(alert.unit.isNotEmpty ? alert.unit : 'AFR',
                        style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: acidLime.withOpacity(0.5)))),
                  ]),
                  const SizedBox(height: 10),
                  // ★ AFR 偏差バー
                  _afrDeviationBar(alert, toxGreen, acidLime, hi),
                  const SizedBox(height: 10),
                  // 底部状態
                  Text('${_slotLabel(alert)} $deviationJp偏差検出 // MIXTURE DEVIATION',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 13,
                      fontWeight: FontWeight.w800, letterSpacing: 3,
                      color: toxGreen.withOpacity(0.6))),
                  const SizedBox(height: 4),
                  Text('混合気制御系統逸脱 // STOICH RATIO VIOLATED',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5,
                      color: dark.withOpacity(0.7))),
                  const SizedBox(height: 3),
                  Text('CODE: M-${(600 + d.tick % 150)}.${d.tick % 10}',
                    style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: toxGreen.withOpacity(0.2))),
                ]))))),
          ))),
    ];
  }

  /// RICH/LEAN 偏向チップ
  Widget _afrDevChip(String label, bool dim, Color green, Color lime) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: green.withOpacity(dim ? 0.12 : 0.6), width: dim ? 1 : 2),
      color: dim ? Colors.transparent : green.withOpacity(0.12)),
    child: Text(label, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 12,
      fontWeight: FontWeight.w900, letterSpacing: 2,
      color: dim ? green.withOpacity(0.2) : lime)));

  /// AFR 偏差バー — 中心 14.7(λ=1.0) 基準, 左=RICH 右=LEAN
  Widget _afrDeviationBar(ActiveAlert alert, Color green, Color lime, bool hi) {
    // AFR基準: 14.7 が理想 → λ に変換して偏差計算
    final double lambda = alert.value / 14.7;
    final dev = (lambda - 1.0).clamp(-0.4, 0.4); // -0.4~+0.4 の範囲
    final pct = (dev / 0.4).clamp(-1.0, 1.0);    // -1~+1 に正規化

    const segs = 20;
    const mid = segs ~/ 2;

    return SizedBox(width: 260, height: 16,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('R ', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 9,
          fontWeight: FontWeight.w900, color: green.withOpacity(0.6))),
        Expanded(child: Row(children: List.generate(segs, (i) {
          final isMid = i == mid || i == mid - 1;
          final active = pct < 0
              ? (i >= mid + (pct * mid).round() && i < mid) // RICH: left of center
              : (i >= mid && i < mid + (pct * mid).round()); // LEAN: right of center
          Color c;
          if (isMid) {
            c = green.withOpacity(0.5);
          } else if (active) {
            c = (hi ? lime : green).withOpacity(hi ? 0.8 : 0.35);
          } else {
            c = green.withOpacity(0.06);
          }
          return Expanded(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 0.5), color: c));
        }))),
        Text(' L', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 9,
          fontWeight: FontWeight.w900, color: green.withOpacity(0.6))),
      ]));
  }

  /// 通用红色闪烁
  List<Widget> _genericOverlay(ActiveAlert alert) => [
    Positioned.fill(child: IgnorePointer(
      child: AnimatedOpacity(
        opacity: _slowFlash ? 0.8 : 0.3,
        duration: const Duration(milliseconds: 150),
        child: Container(
          color: _red.withOpacity(0.12),
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: _red, width: 3),
                color: Colors.black.withOpacity(0.7)),
              child: Text(alert.titleJp.isNotEmpty ? alert.titleJp : '警報',
                style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: _slowFlash ? Colors.white : _red,
                  shadows: [Shadow(color: _red, blurRadius: 40)]))),
            const SizedBox(height: 6),
            Text('${_slotLabel(alert)} ${alert.titleEn.isNotEmpty ? alert.titleEn : "ALERT"} // ${alert.value.toStringAsFixed(1)}${alert.unit}',
              style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 10,
                fontWeight: FontWeight.w800, letterSpacing: 3, color: _red.withOpacity(0.7))),
          ])))))),
  ];

  /// 从 ChannelDisplay 取 label
  String _slotLabel(ActiveAlert alert) {
    final idx = alert.slot.index;
    return d.channelDisplays.length > idx ? d.channelDisplays[idx].label : 'CH${idx + 1}';
  }

  // ════════════════════════════════════════
  // 顶部横幅
  // ════════════════════════════════════════
  Widget _topBanner() {
    final rpm = _v('rpm');
    const seg = 28;
    final lit = ((rpm / d.rpmMax) * seg).round().clamp(0, seg);
    final atRL = rpm >= d.shiftRpm;

    return Container(
      margin: const EdgeInsets.fromLTRB(3, 1, 3, 0),
      decoration: BoxDecoration(border: Border.all(color: _mc.withOpacity(0.25), width: 1)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(height: 12, width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          color: _mc.withOpacity(0.05),
          child: Row(children: [
            // ★ 动态标签 — 从 activeAlerts 生成
            ...d.activeAlerts.map((a) => _tag(
              a.titleJp.isNotEmpty ? a.titleJp : _slotLabel(a))),
            if (d.wShift) _tag('回転限界'),
            if (d.wFullThrottle) _tag('全力全開'),
            const Spacer(),
            Text(_statusText(),
              style: _ts(7, _mc.withOpacity(0.55), w: FontWeight.w700, sp: 0.8)),
          ])),
        SizedBox(height: 12, child: Row(children: List.generate(seg, (i) {
          final on = i < lit;
          final frac = i / (seg - 1);
          final c = frac < 0.6 ? _amber : (frac < 0.85 ? _yellow : _red);
          final strobe = atRL && d.flashOn;
          return Expanded(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 0.3, vertical: 1),
            color: (on || strobe) ? (strobe ? Colors.white : c) : c.withOpacity(0.03)));
        }))),
      ]));
  }

  String _statusText() {
    final top = _top;
    if (top != null) {
      if (top.style == AlertStyle.emergency || top.style == AlertStyle.fuelCritical || top.style == AlertStyle.afrAnomaly) {
        return 'SYSTEM STATUS: EMERGENCY // ${top.titleJp.isNotEmpty ? "${top.titleJp}発令" : "非常事態発令"}';
      }
      return 'SYSTEM STATUS: ${top.titleEn.isNotEmpty ? top.titleEn : "ALERT"} WARNING // ${top.titleJp.isNotEmpty ? "${top.titleJp}警報" : "警報発令"}';
    }
    if (d.wFullThrottle) return 'SYSTEM STATUS: FULL THROTTLE // S²機関 最大出力解放';
    if (d.wShift) return 'SYSTEM STATUS: OVER REV // 回転数超過';
    return 'SYSTEM STATUS: SYNCHRONIZATION ACTIVE // 同期中';
  }

  Widget _tag(String t) => Container(
    margin: const EdgeInsets.only(right: 3),
    padding: const EdgeInsets.symmetric(horizontal: 3),
    color: d.flashOn ? _red : _red.withOpacity(0.25),
    child: Text(t, style: _ts(6, d.flashOn ? Colors.white : _red, w: FontWeight.w900)));

  Widget _hexStream() {
    final o = (d.tick * 2) % _hex.length;
    final s = '${_hex.substring(o)} ${_hex.substring(0, o)}';
    return Container(height: 9, width: double.infinity,
      margin: const EdgeInsets.fromLTRB(3, 0, 3, 0),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      color: _mc.withOpacity(0.02),
      child: Text(s, maxLines: 1, overflow: TextOverflow.clip,
        style: _ts(6.5, _mc.withOpacity(0.15), sp: 1.5)));
  }

  // ════════════════════════════════════════
  // 左翼: ch0 + ch1 + 系统自检
  // ════════════════════════════════════════
  Widget _leftWing() {
    final ch0 = d.channelDisplays.isNotEmpty ? d.channelDisplays[0] : null;
    final ch1 = d.channelDisplays.length > 1 ? d.channelDisplays[1] : null;
    final v0 = ch0?.value ?? 0;
    final v1 = ch1?.value ?? 0;
    return Padding(padding: const EdgeInsets.fromLTRB(3, 0, 0, 0),
      child: Column(children: [
        Expanded(child: Row(children: [
          if (ch0 != null) Expanded(flex: 3, child: _gauge(
            ch0.label, ch0.jpLabel, ch0.unit,
            v0, ch0.gaugeMax, ch0.caution, ch0.danger,
            v0 < ch0.caution ? _amber : (v0 < ch0.danger ? _yellow : _red))),
          const SizedBox(width: 2),
          if (ch1 != null) Expanded(flex: 2, child: _gauge(
            ch1.label, ch1.jpLabel, ch1.unit,
            v1, ch1.gaugeMax, ch1.caution, ch1.danger,
            v1 < ch1.caution ? _amber : (v1 < ch1.danger ? _yellow : _red))),
        ])),
        Container(width: double.infinity, padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: _mc.withOpacity(0.08)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: _scrollingChecks())),
      ]));
  }

  // ════════════════════════════════════════
  // 右翼: ch2 + ch3 + ch4 + ch5 + 自检
  // ════════════════════════════════════════
  Widget _rightWing() {
    final ch2 = d.channelDisplays.length > 2 ? d.channelDisplays[2] : null;
    final ch3 = d.channelDisplays.length > 3 ? d.channelDisplays[3] : null;
    final ch4 = d.channelDisplays.length > 4 ? d.channelDisplays[4] : null;
    final ch5 = d.channelDisplays.length > 5 ? d.channelDisplays[5] : null;
    final v2 = ch2?.value ?? 0;
    final v3 = ch3?.value ?? 0;
    final v4 = ch4?.value ?? 0;
    final v5 = ch5?.value ?? 0;

    return Padding(padding: const EdgeInsets.fromLTRB(0, 0, 3, 0),
      child: Column(children: [
        Container(width: double.infinity, padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _mc.withOpacity(0.08)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _chk('MAGI-01 MELCHIOR', _critical ? 'DIVIDED' : 'AGREE', right: true),
            _chk('MAGI-02 BALTHASAR', 'AGREE', right: true),
            _chk('MAGI-03 CASPER', (_top?.style == AlertStyle.emergency || _top?.style == AlertStyle.fuelCritical || _top?.style == AlertStyle.afrAnomaly) ? 'DISAGREE' : 'AGREE', right: true),
            _chk('SIGNAL NOISE', '${(0.02 + (d.tick % 17) * 0.003).toStringAsFixed(3)}dB', right: true),
            _chk('PATTERN', _critical ? 'RED' : 'BLUE', right: true),
          ])),
        Expanded(flex: 3, child: Row(children: [
          if (ch2 != null) Expanded(child: _gauge(
            ch2.label, ch2.jpLabel, ch2.unit,
            v2, ch2.gaugeMax, ch2.caution, ch2.danger,
            v2 < ch2.caution ? _amber : (v2 < ch2.danger ? _yellow : _red))),
          const SizedBox(width: 2),
          if (ch3 != null) Expanded(child: _gauge(
            ch3.label, ch3.jpLabel, ch3.unit,
            v3, ch3.gaugeMax, ch3.caution, ch3.danger,
            v3 < ch3.caution ? _amber : (v3 < ch3.danger ? _yellow : _red))),
        ])),
        const SizedBox(height: 2),
        if (ch4 != null) _dataRow(
          '${ch4.label} // ${ch4.jpLabel}',
          '${v4.toStringAsFixed(1)} ${ch4.unit}',
          sub: ch4.isDanger ? 'PATTERN RED' : '',
          alert: ch4.isDanger),
        const SizedBox(height: 2),
        if (ch5 != null) _dataRow(
          '${ch5.label} // ${ch5.jpLabel}',
          v5 > 0.5 ? '-${v5.toStringAsFixed(1)}${ch5.unit}' : '0.0${ch5.unit}',
          sub: ch5.isDanger ? 'PATTERN RED' : '',
          alert: ch5.isDanger),
      ]));
  }

  Widget _dataRow(String label, String value, {String sub = '', bool alert = false}) {
    final c = alert ? _red : _amber;
    return Container(height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: alert && d.flashOn ? _red.withOpacity(0.06) : Colors.transparent,
        border: Border.all(color: c.withOpacity(alert ? 0.4 : 0.12), width: 1)),
      child: Row(children: [
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: _ts(6.5, c.withOpacity(0.45), w: FontWeight.w700)),
            if (sub.isNotEmpty) Text(sub, style: _ts(5.5, alert ? _red.withOpacity(0.6) : c.withOpacity(0.25))),
          ])),
        Text(value, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 20,
          fontWeight: FontWeight.w900, color: alert && d.flashOn ? Colors.white : c,
          shadows: [Shadow(color: c.withOpacity(0.4), blurRadius: 6)])),
      ]));
  }

  Widget _chk(String label, String val, {bool right = false}) {
    final alert = val == 'UNSTABLE' || val == 'DIVIDED' || val == 'DISAGREE' || val == 'RED' || val == 'ACTIVE';
    final c = alert ? _red.withOpacity(0.5) : _mc.withOpacity(0.2);
    return Padding(padding: const EdgeInsets.only(bottom: 0.5),
      child: Text('$label: $val', style: _ts(5, c, w: FontWeight.w700, sp: 0.3),
        textAlign: right ? TextAlign.right : TextAlign.left));
  }

  List<Widget> _scrollingChecks() {
    final pool = <MapEntry<String, String>>[
      MapEntry('LCL PRESSURE', _critical ? 'UNSTABLE' : 'STABLE'),
      MapEntry('A.T.FIELD', d.slipping ? 'ACTIVE' : 'STANDBY'),
      MapEntry('PILOT SYNC', '${(40 + _v("rpm") / 200).toStringAsFixed(1)}%'),
      MapEntry('NEURAL LINK', 'ESTABLISHED'),
      MapEntry('INT.BATTERY', '4:${(59 - d.tick % 60).toString().padLeft(2,"0")}'),
      MapEntry('ENTRY PLUG', 'INSERTED'),
      MapEntry('UMBILICAL', 'CONNECTED'),
      MapEntry('S2 ENGINE', _v('rpm') > 6000 ? 'ACTIVE' : 'STANDBY'),
      MapEntry('PROG KNIFE', 'DEPLOYED'),
      MapEntry('ARMOR PLATE', '${(98 - (d.tick % 7) * 0.3).toStringAsFixed(1)}%'),
      MapEntry('CORE TEMP', '${(36.5 + (d.tick % 13) * 0.1).toStringAsFixed(1)}°C'),
      MapEntry('NERVE PULSE', '${120 + d.tick % 40} BPM'),
      MapEntry('DUMMY PLUG', 'OFFLINE'),
      MapEntry('EGO BORDER', 'MAINTAINED'),
      MapEntry('CONTAMINATION', '${(d.tick % 9) * 0.01}%'),
      MapEntry('HARMONICS', '${(88 + d.tick % 12).toStringAsFixed(0)}%'),
    ];
    final offset = (d.tick ~/ 2) % pool.length;
    const show = 7;
    return List.generate(show, (i) {
      final entry = pool[(offset + i) % pool.length];
      return _chk(entry.key, entry.value);
    });
  }

  // ════════════════════════════════════════
  // 中央巨核
  // ════════════════════════════════════════
  Widget _centerMega() {
    final gear = _v('gear').round();
    final speed = _v('speed').round();
    final bool obdMode = d.obdGearMode;

    // ── 档位显示逻辑 ──
    final bool standbyMode;
    final String gearStr;
    final bool isReverse;

    if (obdMode) {
      // OBD 实际档位: -2=R过渡, -1=R, 0=P/N, 1~7=D档
      isReverse = gear < 0;
      final isParkNeutral = gear == 0;
      standbyMode = isParkNeutral;
      if (isParkNeutral) {
        gearStr = '';              // standby → 出撃待命
      } else if (isReverse) {
        gearStr = 'REVERSE';       // 倒档 → REVERSE
      } else if (speed == 0) {
        gearStr = '予備';           // D档 + 停车 → 予備
      } else {
        gearStr = '$gear';         // D档 + 行驶 → 数字
      }
    } else {
      // 計算档位: 0=无法判定, 1~N=正常
      isReverse = false;
      standbyMode = speed == 0;
      gearStr = speed == 0 ? '' : (gear == 0 ? '予備' : (gear < 0 ? 'R' : '$gear'));
    }

    final rpm = _v('rpm');
    final torque = _v('torque_actual').round();
    final rpmC = rpm >= d.shiftRpm ? _red : _amber;

    return Stack(children: [
      if (d.slipping) Positioned(top: 8, right: 12,
        child: AnimatedOpacity(
          opacity: d.flashOn ? 1 : 0.0, duration: const Duration(milliseconds: 50),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(border: Border.all(color: _yellow.withOpacity(0.6), width: 1.5),
              color: Colors.black.withOpacity(0.55)),
            child: Text('TCS 牽引制御', style: _ts(18, _yellow, w: FontWeight.w900, sp: 2,
              shadows: [Shadow(color: _yellow, blurRadius: 14)]))))),

      Positioned.fill(child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _miniData('ACCEL', '${_v("accel_pedal").round()}%'),
              _miniData(
                d.channelDisplays.isNotEmpty ? '${d.channelDisplays[0].label} TGT' : 'TGT',
                _v("boost_target").toStringAsFixed(1)),
              _miniData('GEAR RATIO',
                obdMode
                    ? (isReverse ? 'REV' : (gear > 0 ? 'D$gear' : '--'))
                    : (gear > 0 && gear <= HudChannelStore.gearRatios.length
                        ? HudChannelStore.gearRatios[gear - 1].toStringAsFixed(3) : '--')),
            ])),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$speed', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 52,
                  fontWeight: FontWeight.w900, height: 1, color: _mc,
                 
                  shadows: [Shadow(color: _mc.withOpacity(0.4), blurRadius: 16)])),
                Padding(padding: const EdgeInsets.only(bottom: 6, left: 2),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('km/h', style: _ts(9, _mc.withOpacity(0.5), w: FontWeight.w700)),
                    Text('速度', style: _ts(8, _mc.withOpacity(0.2))),
                  ])),
              ]),
            ]),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _miniData(
                d.channelDisplays.length > 4 ? d.channelDisplays[4].label : 'CH5',
                d.channelDisplays.length > 4 ? d.channelDisplays[4].value.toStringAsFixed(2) : '--'),
              _miniData(
                d.channelDisplays.length > 2 ? d.channelDisplays[2].label : 'CH3',
                d.channelDisplays.length > 2 ? '${d.channelDisplays[2].value.round()}${d.channelDisplays[2].unit}' : '--'),
              _miniData(
                d.channelDisplays.length > 3 ? d.channelDisplays[3].label : 'CH4',
                d.channelDisplays.length > 3 ? '${d.channelDisplays[3].value.round()}${d.channelDisplays[3].unit}' : '--'),
            ])),
          ])),

        Expanded(child: _gearMega(gearStr, rpmC, standbyMode, isReverse)),

        Container(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _magiBar(),
            const SizedBox(height: 1),
            Row(children: [
              Expanded(child: Row(children: [
                Text('${rpm.round()}', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 28,
                  fontWeight: FontWeight.w900, color: rpmC,
                 
                  shadows: [Shadow(color: rpmC.withOpacity(0.5), blurRadius: 10)])),
                const SizedBox(width: 3),
                Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('RPM', style: _ts(8, rpmC.withOpacity(0.5), w: FontWeight.w700)),
                  Text('回転数', style: _ts(6, rpmC.withOpacity(0.2))),
                ]),
              ])),
              Container(width: 1, height: 28, color: _mc.withOpacity(0.1)),
              Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('Nm', style: _ts(8, _amber.withOpacity(0.5), w: FontWeight.w700)),
                  Text('トルク', style: _ts(6, _amber.withOpacity(0.2))),
                ]),
                const SizedBox(width: 3),
                Text('$torque', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 28,
                  fontWeight: FontWeight.w900, color: _amber,
                 
                  shadows: [Shadow(color: _amber.withOpacity(0.5), blurRadius: 10)])),
              ])),
            ]),
            const SizedBox(height: 1),
            Row(children: [
              _miniData('POWER', '${(torque * rpm / 9549).round()} kW'),
              const Spacer(),
              _miniData('ENGINE LOAD', '${((_v("accel_pedal") * 0.95).round())}%'),
              const Spacer(),
              _miniData('FUEL TRIM', '+${(d.tick % 5).toStringAsFixed(1)}%'),
            ]),
          ])),
      ])),
    ]);
  }

  Widget _gearMega(String gearStr, Color c, bool standby, bool isReverse) {
    // REVERSE 用独特的红色方案
    final Color reverseColor = _red;
    return TweenAnimationBuilder<double>(
      key: ValueKey(standby ? -999 : (isReverse ? -888 : d.gearChangeKey)),
      tween: Tween(begin: 1.12, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.elasticOut,
      builder: (_, scale, __) => Transform.scale(scale: scale,
        child: LayoutBuilder(builder: (_, box) {
          return Stack(children: [
            Positioned.fill(child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(
                  color: isReverse ? reverseColor.withOpacity(0.5) : _mc.withOpacity(0.35),
                  width: 2),
                color: isReverse ? reverseColor.withOpacity(0.025) : _mc.withOpacity(0.015)),
              child: Stack(children: [
                ..._corners(isReverse ? reverseColor.withOpacity(0.35) : _mc.withOpacity(0.25)),
                Positioned(top: 4, left: 6, child: Text(
                  standby ? 'STANDBY MODE' : (isReverse ? 'REVERSE GEAR' : 'CURRENT GEAR'),
                  style: _ts(10, isReverse ? reverseColor.withOpacity(0.6) : _mc.withOpacity(0.45),
                    w: FontWeight.w900, sp: 1.5))),
                Positioned(top: 16, left: 6, child: Text(
                  standby ? '待命状態' : (isReverse ? '後退操作' : '主変速器'),
                  style: _ts(12, isReverse ? reverseColor.withOpacity(0.45) : _mc.withOpacity(0.35),
                    w: FontWeight.w900))),
                Positioned(top: 4, right: 6, child: Text(
                  standby ? 'ENGINE IDLE'
                      : (isReverse ? 'CAUTION' : 'TRANSMISSION ${_em ? "ALERT" : "NOMINAL"}'),
                  style: _ts(7, isReverse ? reverseColor.withOpacity(0.5)
                      : (_em ? _red.withOpacity(0.5) : _mc.withOpacity(0.25)), w: FontWeight.w800))),
                Positioned(bottom: 4, left: 6, child: Text('変速機 UNIT-01',
                  style: _ts(9, isReverse ? reverseColor.withOpacity(0.3) : _mc.withOpacity(0.25),
                    w: FontWeight.w800))),
                Positioned(bottom: 4, right: 6, child: Text(
                  standby ? 'READY' : 'SYNC: ${(40 + _v("rpm") / 200).toStringAsFixed(1)}%',
                  style: _ts(8, isReverse ? reverseColor.withOpacity(0.3) : _mc.withOpacity(0.25),
                    w: FontWeight.w800))),
                Center(child: FittedBox(fit: BoxFit.contain,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
                    child: standby
                      ? Text('出撃待命', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                          fontWeight: FontWeight.w900, height: 0.85,
                          fontSize: 120,
                          color: _amber.withOpacity(d.tick % 6 < 3 ? 0.7 : 0.35),
                          shadows: [
                            Shadow(color: _amber.withOpacity(0.3), blurRadius: 30),
                          ]))
                      : isReverse
                      ? Text('REVERSE', style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                          fontWeight: FontWeight.w900, height: 0.85,
                          fontSize: 150,
                          color: reverseColor.withOpacity(d.tick % 4 < 2 ? 0.9 : 0.5),
                          shadows: [
                            Shadow(color: reverseColor.withOpacity(0.6), blurRadius: 40),
                            Shadow(color: reverseColor.withOpacity(0.2), blurRadius: 100),
                          ]))
                      : Text(gearStr, style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
                          fontWeight: FontWeight.w900, height: 0.85,
                          fontSize: gearStr == '予備' ? 200 : 300,
                          color: _em && d.flashOn ? _red : c,
                          shadows: [
                            Shadow(color: c.withOpacity(0.5), blurRadius: 40),
                            Shadow(color: c.withOpacity(0.15), blurRadius: 100),
                          ]))))),
              ]))),
          ]);
        })));
  }

  List<Widget> _corners(Color c) {
    const s = 10.0;
    return [
      Positioned(top: 0, left: 0, child: _cornerL(s, c, false, false)),
      Positioned(top: 0, right: 0, child: _cornerL(s, c, true, false)),
      Positioned(bottom: 0, left: 0, child: _cornerL(s, c, false, true)),
      Positioned(bottom: 0, right: 0, child: _cornerL(s, c, true, true)),
    ];
  }

  Widget _cornerL(double s, Color c, bool fh, bool fv) => SizedBox(width: s, height: s,
    child: CustomPaint(painter: _CornerP(c, 1.5, fh, fv)));

  Widget _magiBar() {
    final f1 = (d.tick % 7) < 1;
    final f2 = (d.tick % 11) < 1;
    final f3 = (d.tick % 5) < 1;
    final fM = (d.tick % 13) < 2;

    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      AnimatedOpacity(opacity: f1 ? 0.0 : 1.0, duration: const Duration(milliseconds: 50),
        child: _mChip('MELCHIOR·1', !_critical)),
      const SizedBox(width: 4),
      AnimatedOpacity(opacity: fM ? 0.0 : 1.0, duration: const Duration(milliseconds: 50),
        child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(border: Border.all(color: _mc.withOpacity(0.2), width: 0.5)),
          child: Text('MAGI', style: _ts(7, _mc.withOpacity(0.4), w: FontWeight.w900, sp: 2)))),
      const SizedBox(width: 4),
      AnimatedOpacity(opacity: f2 ? 0.0 : 1.0, duration: const Duration(milliseconds: 50),
        child: _mChip('BALTHASAR·2', !_critical)),
      const SizedBox(width: 4),
      AnimatedOpacity(opacity: f3 ? 0.0 : 1.0, duration: const Duration(milliseconds: 50),
        child: _mChip('CASPER·3', _top?.style != AlertStyle.emergency && _top?.style != AlertStyle.fuelCritical && _top?.style != AlertStyle.afrAnomaly)),
    ]);
  }

  Widget _mChip(String n, bool ok) {
    final c = ok ? _amber : _red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.withOpacity(ok ? 0.05 : 0.08),
        border: Border.all(color: c.withOpacity(0.25), width: 0.5)),
      child: Text('${n.split("·")[0].substring(0,3)}·${n.split("·")[1]} ${ok ? "○" : "×"}',
        style: _ts(5.5, c.withOpacity(ok ? 0.45 : 0.7), w: FontWeight.w800)));
  }

  Widget _miniData(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 0.5),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label:', style: _ts(5, _mc.withOpacity(0.2), w: FontWeight.w700, sp: 0.3)),
      const SizedBox(width: 2),
      Text(value, style: _ts(5.5, _mc.withOpacity(0.35), w: FontWeight.w900)),
    ]));

  // ════════════════════════════════════════
  // 分段仪表
  // ════════════════════════════════════════
  Widget _gauge(String label, String sub, String unit,
    double val, double max, double cAt, double dAt, Color color) {
    final pct = (val / max).clamp(0.0, 1.0);
    final danger = val >= dAt;
    final caution = val >= cAt && !danger;
    const segs = 20;
    final litSegs = (pct * segs).round().clamp(0, segs);
    final cSeg = ((cAt / max) * segs).round().clamp(0, segs);
    final dSeg = ((dAt / max) * segs).round().clamp(0, segs);

    return Column(children: [
      SizedBox(width: double.infinity, child: FittedBox(fit: BoxFit.scaleDown, child:
        Text(val.toStringAsFixed(val == val.roundToDouble() ? 0 : 1), maxLines: 1,
          style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud], fontSize: 28,
            fontWeight: FontWeight.w900, color: danger && d.flashOn ? Colors.white : color,
            shadows: [Shadow(color: color.withOpacity(0.5), blurRadius: 8)])))),
      Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Text(unit, style: _ts(8, color.withOpacity(0.45), w: FontWeight.w700)),
        Text(d.tick % 5 < 2 ? ' ↑' : ' ↓', style: _ts(7, color.withOpacity(0.25), w: FontWeight.w900)),
      ]),
      const SizedBox(height: 1),
      Expanded(child: Container(
        decoration: BoxDecoration(border: Border.all(color: color.withOpacity(0.1), width: 1)),
        child: LayoutBuilder(builder: (_, box) => Stack(children: [
          Column(verticalDirection: VerticalDirection.up, children:
            List.generate(segs, (i) {
              final on = i < litSegs;
              final inD = i >= dSeg;
              final inC = i >= cSeg && i < dSeg;
              final segC = inD ? _red : (inC ? _yellow : color);
              return Expanded(child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 0.5, vertical: 0.3),
                color: on ? segC.withOpacity(0.85) : segC.withOpacity(0.025)));
            })),
          Positioned(left: 0, right: 0, bottom: box.maxHeight * (cAt / max),
            child: Container(height: 1, color: _yellow.withOpacity(0.35))),
          Positioned(right: 1, bottom: box.maxHeight * (cAt / max) + 1,
            child: Text('C', style: _ts(4.5, _yellow.withOpacity(0.45), w: FontWeight.w900))),
          Positioned(left: 0, right: 0, bottom: box.maxHeight * (dAt / max),
            child: Container(height: 1.5, color: _red.withOpacity(0.45))),
          Positioned(right: 1, bottom: box.maxHeight * (dAt / max) + 1,
            child: Text('D', style: _ts(4.5, _red.withOpacity(0.5), w: FontWeight.w900))),
        ])))),
      const SizedBox(height: 1),
      if (danger) _statusTag('DANGER', _red)
      else if (caution) _statusTag('CAUTION', _yellow)
      else const SizedBox(height: 8),
      Text(label, style: _ts(8, color.withOpacity(0.6), w: FontWeight.w900, sp: 1)),
      Text(sub, style: _ts(6, color.withOpacity(0.25))),
    ]);
  }

  Widget _statusTag(String t, Color c) => Container(width: double.infinity, height: 8,
    color: d.flashOn ? c.withOpacity(0.15) : Colors.transparent,
    child: Center(child: Text(t, style: _ts(5, c.withOpacity(0.8), w: FontWeight.w900))));

  // ════════════════════════════════════════
  // 底部
  // ════════════════════════════════════════
  Widget _bottomTriple() => Container(
    margin: const EdgeInsets.fromLTRB(3, 0, 3, 1),
    decoration: BoxDecoration(border: Border.all(color: _mc.withOpacity(0.15), width: 1)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      // ★ 油門踏板バー — 基幹監視
      _throttleBar(),
      Container(height: 0.5, color: _mc.withOpacity(0.06)),
      SizedBox(height: 16, child: Row(children: [
        _bCell('MAX ${d.channelDisplays.isNotEmpty ? d.channelDisplays[0].label : "BOOST"}',
          '${d.peakBoost.toStringAsFixed(1)} ${d.channelDisplays.isNotEmpty ? d.channelDisplays[0].unit : "psi"}'),
        _bDiv(), _bCell('PEAK TQ', '${d.peakTorque.round()} Nm'),
        _bDiv(), _bCell('LAT-G', d.peakLatG.toStringAsFixed(2)),
        _bDiv(), _bCell('LON-G', d.peakLonG.toStringAsFixed(2)),
        _bDiv(), _bCell('STATUS', _em ? 'ALERT' : 'NOMINAL'),
      ])),
      Container(height: 0.5, color: _mc.withOpacity(0.06)),
      Container(height: 11, padding: const EdgeInsets.symmetric(horizontal: 3),
        color: _mc.withOpacity(0.02),
        child: Row(children: [
          Text('E.V.A. UNIT-01 // 初号機', style: _ts(5.5, _mc.withOpacity(0.25), w: FontWeight.w700, sp: 0.8)),
          const Spacer(),
          Text('汎用ヒト型決戦兵器 // 人造人間エヴァンゲリオン', style: _ts(5.5, _mc.withOpacity(0.15))),
        ])),
      Container(height: 0.5, color: _mc.withOpacity(0.06)),
      Container(height: 10, padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Row(children: [
          Text('LOG>', style: _ts(6, _mc.withOpacity(0.2), w: FontWeight.w900)),
          const SizedBox(width: 3),
          Expanded(child: Text(_logText(),
            maxLines: 1, overflow: TextOverflow.clip,
            style: _ts(5.5, _logColor(), sp: 0.5))),
        ])),
    ]));

  /// ★ 油門踏板バー — 基幹監視 (不占用通道槽位)
  Widget _throttleBar() {
    final pct = _v('accel_pedal').clamp(0, 100);
    final ratio = pct / 100;
    final isFull = pct >= 98;
    // 高油门 → 红色, 中油门 → 琥珀, 低油门 → 暗色
    final barColor = isFull
        ? (d.flashOn ? Colors.white : _red)
        : (pct > 60 ? _red.withOpacity(0.7) : _amber.withOpacity(0.5));

    return SizedBox(height: 10, child: LayoutBuilder(
      builder: (_, box) {
        final w = box.maxWidth;
        return Stack(children: [
          // 背景
          Positioned.fill(child: Container(color: _mc.withOpacity(0.03))),
          // 填充条 — 从左到右增长
          Positioned(left: 0, top: 0, bottom: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: ratio * w,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  barColor.withOpacity(0.15),
                  barColor.withOpacity(isFull ? 0.5 : 0.3),
                ])))),
          // 左侧标签
          Positioned(left: 3, top: 0, bottom: 0,
            child: Center(child: Text('ACCEL //アクセル',
              style: _ts(5.5, _mc.withOpacity(0.3), w: FontWeight.w800, sp: 1)))),
          // 右侧数值
          Positioned(right: 3, top: 0, bottom: 0,
            child: Center(child: Text('${pct.round()}%',
              style: _ts(7, barColor, w: FontWeight.w900)))),
          // 刻度线 (25% 50% 75%)
          for (final mark in [0.25, 0.5, 0.75])
            Positioned(left: mark * w, top: 0, bottom: 0, width: 1,
              child: Container(color: _mc.withOpacity(0.08))),
        ]);
      }));
  }

  String _logText() {
    final top = _top;
    if (top != null) {
      final label = _slotLabel(top);
      if (top.style == AlertStyle.emergency) {
        return 'EMERGENCY: $label DETECTED // ABORT MISSION? // OPERATION YASHIMA CANCELLED';
      }
      if (top.style == AlertStyle.fuelCritical) {
        return 'CRITICAL: $label SUPPLY FAILURE // 燃料系統崩壊 // ENGINE SHUTDOWN IMMINENT // 生命線断絶';
      }
      if (top.style == AlertStyle.afrAnomaly) {
        return 'CRITICAL: $label 混合気異常 // AFR DEVIATION DETECTED // STOICH RATIO VIOLATED // 空燃比逸脱';
      }
      return 'WARNING: $label ${top.titleEn} // REDUCE LOAD // 出力制限中';
    }
    if (d.wFullThrottle) return 'リミッター解除 // FULL THROTTLE ENGAGED // S² ENGINE OUTPUT: MAXIMUM // 全力全開発動中';
    if (d.wShift) return 'OVER REV WARNING // SHIFT UP IMMEDIATELY // 回転数超過注意';
    return 'ALL SYSTEMS NOMINAL // NEURAL HANDSHAKE: 100% // OPERATION YASHIMA STANDBY // ヤシマ作戦準備完了';
  }

  Color _logColor() {
    final top = _top;
    if (top != null) {
      if (top.style == AlertStyle.emergency) return _red.withOpacity(0.35);
      if (top.style == AlertStyle.fuelCritical) return const Color(0xFFFF0050).withOpacity(0.35);
      if (top.style == AlertStyle.afrAnomaly) return const Color(0xFF76FF03).withOpacity(0.35);
      return const Color(0xFFFF4400).withOpacity(0.3);
    }
    return _em ? _amber.withOpacity(0.25) : _mc.withOpacity(0.12);
  }

  Widget _bCell(String l, String v) => Expanded(child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    color: l == 'STATUS' && _em && d.flashOn ? _red.withOpacity(0.08) : Colors.transparent,
    child: Row(children: [
      Text('$l:', style: _ts(5, _mc.withOpacity(0.3), w: FontWeight.w700)),
      const Spacer(),
      Text(v, style: _ts(7.5, l == 'STATUS' && _em ? _red : _mc, w: FontWeight.w900)),
    ])));

  Widget _bDiv() => Container(width: 0.5, color: _mc.withOpacity(0.06));

  TextStyle _ts(double sz, Color c, {FontWeight w = FontWeight.w600, double sp = 0,
    List<Shadow>? shadows}) =>
    TextStyle(fontFamily: 'monospace', fontFamilyFallback: const [kFontHud],
      fontSize: sz, fontWeight: w,
      letterSpacing: sp, color: c, shadows: shadows);
}

// ════════════════════════════════════════════════════════════════
// Painters
// ════════════════════════════════════════════════════════════════

class _HexGridPainter extends CustomPainter {
  final Color mc;
  const _HexGridPainter({required this.mc});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 0.5..color = mc.withOpacity(0.05);
    const r = 16.0;
    final dx = r * 1.5;
    final dy = r * math.sqrt(3);
    int row = 0;
    for (double y = -r; y < size.height + r; y += dy * 0.5) {
      final ox = (row % 2 == 0) ? 0.0 : dx;
      for (double x = -r + ox; x < size.width + r; x += dx * 2) {
        final path = Path();
        for (int i = 0; i < 6; i++) {
          final a = (math.pi / 3) * i - math.pi / 6;
          final pt = Offset(x + r * math.cos(a), y + r * math.sin(a));
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        path.close();
        canvas.drawPath(path, p);
      }
      row++;
    }
  }
  @override bool shouldRepaint(_HexGridPainter old) => old.mc != mc;
}

class _CrtPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withOpacity(0.14);
    for (double y = 0; y < size.height; y += 2.5) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }
  @override bool shouldRepaint(_CrtPainter old) => false;
}

class _HazardPainter extends CustomPainter {
  final bool flash;
  const _HazardPainter({required this.flash});
  @override
  void paint(Canvas canvas, Size size) {
    final c1 = flash ? _red : _hazard;
    const sw = 14.0;
    final p1 = Paint()..color = c1.withOpacity(0.7);
    final p2 = Paint()..color = Colors.black;
    for (double x = -size.height; x < size.width + size.height; x += sw * 2) {
      canvas.drawPath(Path()..moveTo(x, size.height)..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + sw, 0)..lineTo(x + sw, size.height)..close(), p1);
      canvas.drawPath(Path()..moveTo(x + sw, size.height)..lineTo(x + size.height + sw, 0)
        ..lineTo(x + size.height + sw * 2, 0)..lineTo(x + sw * 2, size.height)..close(), p2);
    }
  }
  @override bool shouldRepaint(_HazardPainter old) => old.flash != flash;
}

class _CornerP extends CustomPainter {
  final Color c; final double t; final bool fh, fv;
  const _CornerP(this.c, this.t, this.fh, this.fv);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = c..strokeWidth = t..style = PaintingStyle.stroke;
    final x0 = fh ? size.width : 0.0;
    final y0 = fv ? size.height : 0.0;
    canvas.drawLine(Offset(x0, y0), Offset(fh ? 0.0 : size.width, y0), p);
    canvas.drawLine(Offset(x0, y0), Offset(x0, fv ? 0.0 : size.height), p);
  }
  @override bool shouldRepaint(_CornerP old) => false;
}

/// ★ 増圧限界: 几何能量扫描条 (替代 HazardPainter 的黄黑条纹)
class _BoostScanPainter extends CustomPainter {
  final bool flash;
  final Color color;
  const _BoostScanPainter({required this.flash, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 交替亮灭的分段能量条
    const segs = 32;
    final segW = w / segs;
    for (int i = 0; i < segs; i++) {
      // 棋盘式闪烁: flash 状态下偶数亮, 非 flash 奇数亮
      final on = flash ? (i % 2 == 0) : (i % 2 == 1);
      final p = Paint()..color = color.withOpacity(on ? 0.55 : 0.08);
      canvas.drawRect(Rect.fromLTWH(i * segW, 0, segW - 1, h), p);
    }
    // 中心高亮线
    final lp = Paint()
      ..color = color.withOpacity(flash ? 0.7 : 0.2)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, h * 0.5), Offset(w, h * 0.5), lp);
  }
  @override bool shouldRepaint(_BoostScanPainter old) => old.flash != flash;
}

/// ★ 全力全開: 高速流動能量条 — 金色脉冲从左向右扫过
class _ThrottleBarPainter extends CustomPainter {
  final int tick;
  final bool flash;
  final Color color;
  const _ThrottleBarPainter({required this.tick, required this.flash, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 底色
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
      Paint()..color = Colors.black.withOpacity(0.6));
    // 流动分段 — 每 tick 偏移产生高速扫描效果
    const segs = 40;
    final segW = w / segs;
    final offset = (tick * 3) % segs; // 高速滚动
    for (int i = 0; i < segs; i++) {
      final shifted = (i + offset) % segs;
      // 三段明暗波形
      final wave = (shifted % 5);
      final bright = wave < 2;
      final op = bright
          ? (flash ? 0.7 : 0.25)
          : (flash ? 0.12 : 0.03);
      canvas.drawRect(
        Rect.fromLTWH(i * segW, 1, segW - 1, h - 2),
        Paint()..color = color.withOpacity(op));
    }
    // 上下亮边
    final ep = Paint()..color = color.withOpacity(flash ? 0.6 : 0.15)..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, 0.5), Offset(w, 0.5), ep);
    canvas.drawLine(Offset(0, h - 0.5), Offset(w, h - 0.5), ep);
  }
  @override bool shouldRepaint(_ThrottleBarPainter old) => old.tick != tick || old.flash != flash;
}

// ════════════════════════════════════════════════════════════════
// ★ 全力全開 — 流線 Painter
// ════════════════════════════════════════════════════════════════

/// ── 滑らかな放射流線 (EV ローンチコントロール風) ─────
/// 中心から外周へ流れる半透明の光線。各線は固定角度 + sine ベースの
/// 滑らかなアニメーション。ランダム性を排除し、流体的な美しさを重視。
class _FtFlowLinePainter extends CustomPainter {
  final int tick;
  final double intensity; // 0.0 ~ 1.0
  const _FtFlowLinePainter({required this.tick, required this.intensity});

  static const _lineCount = 80;

  // 4 色を滑らかにサイクル
  static const _colors = [
    Color(0xFFFFB300), // gold
    Color(0xFFFFF0C0), // warm white
    Color(0xFFFF8F00), // amber
    Color(0xFFFFD54F), // light gold
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final maxR = math.sqrt(cx * cx + cy * cy);
    final t = tick * 0.5; // 時間 (滑らかな進行)

    final paint = Paint()..strokeCap = StrokeCap.round;

    for (int i = 0; i < _lineCount; i++) {
      // 固定角度 (等間隔 + 微小オフセットでランダム感)
      final baseAngle = (math.pi * 2 / _lineCount) * i;
      // 呼吸: 各線が微妙に位相ずれした sine で揺れる
      final angle = baseAngle + math.sin(t * 1.2 + i * 0.7) * 0.03;

      // 流れ: 線の開始・終了位置が時間で外側に移動
      final phase = ((t * 0.8 + i * 0.13) % 1.0);
      final r1 = maxR * (0.05 + phase * 0.4);
      final r2 = r1 + maxR * (0.15 + intensity * 0.35);

      // 太さ: 外側ほど太く + intensity で全体的に太く
      final lw = (0.5 + intensity * 2.0) * (0.6 + phase * 0.8);

      // 透明度: 先端と末端がフェード (sine 曲線)
      final fadeHead = math.sin(phase * math.pi).clamp(0.0, 1.0);
      final alpha = (fadeHead * intensity * 0.55).clamp(0.0, 1.0);
      if (alpha < 0.01) continue;

      final color = _colors[i % _colors.length];
      paint
        ..color = color.withOpacity(alpha)
        ..strokeWidth = lw;

      canvas.drawLine(
        Offset(cx + math.cos(angle) * r1, cy + math.sin(angle) * r1),
        Offset(cx + math.cos(angle) * r2, cy + math.sin(angle) * r2),
        paint);
    }

    // ★ 中心グロー (微かな暖色の光点)
    if (intensity > 0.3) {
      final glowR = 20.0 + intensity * 30.0;
      final glowP = Paint()
        ..color = const Color(0xFFFFB300).withOpacity(intensity * 0.08)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowR);
      canvas.drawCircle(Offset(cx, cy), glowR, glowP);
    }
  }

  @override
  bool shouldRepaint(_FtFlowLinePainter old) =>
      old.tick != tick || old.intensity != intensity;
}
