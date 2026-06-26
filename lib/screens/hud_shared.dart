import 'package:flutter/material.dart';

// ════════════════════════════════════════════════════════════════
// hud_shared.dart — HUD / PERF 共享常量与类型
// ════════════════════════════════════════════════════════════════

// ── 色彩语义 ──
const cCyan    = Color(0xFF00E5FF);
const cLime    = Color(0xFF76FF03);
const cOrange  = Color(0xFFFF9100);
const cLava    = Color(0xFFFF1744);
const cDim     = Color(0xFF3A3A50);
const cLabel   = Color(0xFF8899AA);
const cSlip    = Color(0xFFFFD600);
const hudBg    = Color(0xFF000000);
const hudSurf  = Color(0xCC0A0A10);
const hudLn    = Color(0xAA13131E);

// ── 机械字体 ──
const kFontMech = 'monospace';

// ═══ MatissePro 字体系统 ═══
// 策略: 英数 → monospace (等宽), 日文 CJK → MatissePro (fallback)
const kFontHud = 'MatissePro';   // CJK fallback 字体 (pubspec.yaml 注册)
const kFontFallback = ['monospace'];  // 保留备用
// 字重语义: EN大字=UB(w900), EN标签=EB(w800), JP=B(w700), 混合=EB(w800), 装饰=DB(w600)
const kWtEN   = FontWeight.w900;  // 英文大字 (UB) — 速度/档位/RPM
const kWtENsm = FontWeight.w800;  // 英文标签 (EB) — ACCEL, MAGI, km/h
const kWtJP   = FontWeight.w700;  // 日文 (B) — 出撃待命, 強制升档
const kWtMix  = FontWeight.w800;  // 混合文本 (EB) — "OVERBOOST // 増圧限界"
const kWtDim  = FontWeight.w600;  // 装饰/次要 (DB) — 小字, MAGI 投票

// ── 色域区间 (用于竖条着色) ──
class HudZone {
  final double start, end;
  final Color color;
  const HudZone(this.start, this.end, this.color);
}
