// ════════════════════════════════════════════════════════════════
// eva_theme.dart — EVA 色彩常量 & 共用 Widget
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';

// ── EVA 色彩 ──
const evaAmber = Color(0xFFFF8800);
const evaRed   = Color(0xFFFF1100);
const evaDim   = Color(0xFF553300);
const evaGreen = Color(0xFF00FF88);
const evaCyan  = Color(0xFF00E5FF);

// ── 持久化 Keys ──
const kWpPath       = 'eva_hud_wallpaper_path';
const kWpDark       = 'eva_hud_wallpaper_darkness';
const kBgmOn        = 'eva_hud_bgm_enabled';
const kBgmVol       = 'eva_hud_bgm_volume';
const kSfxVol       = 'eva_hud_sfx_volume';
const kAlertOverlap = 'eva_hud_alert_overlap';
const kCommMode     = 'eva_comm_mode';
const kLinkMode     = 'eva_link_mode';

// ═══════════════════════════════════════════════════════════
// 共用 Widget
// ═══════════════════════════════════════════════════════════

/// EVA 风格卡片容器
class EvaCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget child;

  const EvaCard({
    super.key,
    required this.title,
    this.subtitle = '',
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: DS.surface, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: evaAmber.withOpacity(0.08))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: TextStyle(fontFamily: 'monospace', fontSize: 11,
            fontWeight: FontWeight.w900, letterSpacing: 1.5, color: evaAmber.withOpacity(0.7))),
          if (subtitle.isNotEmpty) ...[const SizedBox(width: 6),
            Text(subtitle, style: TextStyle(fontFamily: 'monospace', fontSize: 8,
              fontWeight: FontWeight.w700, color: evaAmber.withOpacity(0.2)))],
          const Spacer(),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: 10),
        child,
      ]));
  }
}

/// EVA 风格操作按钮
Widget evaActionBtn(String label, IconData icon, Color c, VoidCallback? onTap) {
  return GestureDetector(onTap: onTap, child: Container(
    padding: const EdgeInsets.symmetric(vertical: 7),
    decoration: BoxDecoration(
      color: onTap != null ? c.withOpacity(0.06) : DS.bg,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: c.withOpacity(onTap != null ? 0.2 : 0.05))),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 13, color: c.withOpacity(onTap != null ? 0.6 : 0.2)),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontFamily: 'monospace', fontSize: 10,
        fontWeight: FontWeight.w800, color: onTap != null ? c : c.withOpacity(0.3))),
    ])));
}

/// EVA 风格音量/数值滑块行
Widget evaAudioSlider(String label, double value, Color color, ValueChanged<double> onChanged) {
  return Row(children: [
    SizedBox(width: 62, child: Text(label, style: TextStyle(fontFamily: 'monospace',
      fontSize: 8, fontWeight: FontWeight.w800, color: color))),
    Expanded(child: SliderTheme(
      data: SliderThemeData(trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        activeTrackColor: color, inactiveTrackColor: color.withOpacity(0.15),
        thumbColor: color, overlayColor: color.withOpacity(0.08)),
      child: Slider(value: value, min: 0, max: 1, onChanged: onChanged))),
    SizedBox(width: 28, child: Text('${(value * 100).round()}%', textAlign: TextAlign.right,
      style: TextStyle(fontFamily: 'monospace', fontSize: 9,
        fontWeight: FontWeight.w800, color: color))),
  ]);
}

/// EVA 风格迷你按钮
Widget evaMiniBtn(String label, VoidCallback onTap) {
  return GestureDetector(onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: evaAmber.withOpacity(0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: evaAmber.withOpacity(0.15))),
      child: Text(label, style: TextStyle(fontFamily: 'monospace',
        fontSize: 8, fontWeight: FontWeight.w800, color: evaAmber.withOpacity(0.6)))));
}

/// EVA 风格文本输入行
Widget evaInputRow(String title, TextEditingController ctrl, ValueChanged<String> onChanged) {
  return Padding(padding: const EdgeInsets.only(bottom: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontFamily: 'monospace', fontSize: 9,
        fontWeight: FontWeight.w800, color: evaAmber.withOpacity(0.6))),
      const SizedBox(height: 4),
      SizedBox(height: 36, child: TextField(
        controller: ctrl,
        style: TextStyle(fontFamily: 'monospace', fontSize: 13,
          fontWeight: FontWeight.w800, color: evaAmber),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: evaAmber.withOpacity(0.2))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: evaAmber.withOpacity(0.15))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: evaAmber.withOpacity(0.5))),
          filled: true, fillColor: DS.bg),
        onChanged: onChanged)),
    ]));
}

/// EVA 风格数字输入框
Widget evaNumInput(TextEditingController ctrl, ValueChanged<double> onChanged) {
  return SizedBox(height: 36, child: TextField(
    controller: ctrl,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: TextStyle(fontFamily: 'monospace', fontSize: 14,
      fontWeight: FontWeight.w800, color: evaAmber),
    decoration: InputDecoration(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: evaAmber.withOpacity(0.2))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: evaAmber.withOpacity(0.15))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: evaAmber.withOpacity(0.5))),
      filled: true, fillColor: DS.bg),
    onChanged: (t) { final v = double.tryParse(t); if (v != null) onChanged(v); }));
}

/// EVA 风格阈值标签
Widget evaThresholdLabel(String text, Color color) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(text, style: TextStyle(fontFamily: 'monospace',
    fontSize: 9, fontWeight: FontWeight.w800, color: color.withOpacity(0.7))));

/// 通用编辑对话框
void showEvaEditDialog(BuildContext context, String label, String current,
    ValueChanged<String> onDone, {VoidCallback? onDelete}) {
  final ctrl = TextEditingController(text: current);
  showDialog(context: context, builder: (ctx) => AlertDialog(
    backgroundColor: const Color(0xFF0A0A10),
    title: Text(label, style: TextStyle(fontFamily: 'monospace', fontSize: 13,
      fontWeight: FontWeight.w800, color: evaAmber)),
    content: TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      autofocus: true,
      style: TextStyle(fontFamily: 'monospace', fontSize: 16,
        fontWeight: FontWeight.w900, color: Colors.white),
      decoration: InputDecoration(
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: evaAmber.withOpacity(0.3))),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: evaAmber)))),
    actions: [
      if (onDelete != null) TextButton(
        onPressed: () { Navigator.pop(ctx); onDelete(); },
        child: Text('削除', style: TextStyle(fontFamily: 'monospace', color: evaRed))),
      TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: Text('取消', style: TextStyle(fontFamily: 'monospace', color: DS.textDim))),
      TextButton(
        onPressed: () { Navigator.pop(ctx); onDone(ctrl.text); },
        child: Text('確定', style: TextStyle(fontFamily: 'monospace', color: evaAmber))),
    ]));
}
