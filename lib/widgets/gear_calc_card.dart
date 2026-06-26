// ════════════════════════════════════════════════════════════════
// gear_calc_card.dart — 档位計算器卡片
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../models/obd_pids.dart';
import '../theme/eva_theme.dart';

class GearCalcCard extends StatefulWidget {
  final VoidCallback? onChanged;
  const GearCalcCard({super.key, this.onChanged});
  @override State<GearCalcCard> createState() => _GearCalcCardState();
}

class _GearCalcCardState extends State<GearCalcCard> {
  static const _cyan = Color(0xFF00E5FF);
  static const _green = Color(0xFF76FF03);

  @override
  Widget build(BuildContext context) {
    final source = HudChannelStore.gearSource;
    final ratios = HudChannelStore.gearRatios;
    final fd = HudChannelStore.finalDrive;
    final tw = HudChannelStore.tireWidth;
    final ta = HudChannelStore.tireAspect;
    final tr = HudChannelStore.tireRim;
    final dMm = HudChannelStore.tireDiameterMm;

    return EvaCard(title: 'GEAR CALCULATOR', subtitle: '档位計算器',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── 档位数据源选择 (二択必須) ──
        Text('档位データソース', style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.5))),
        const SizedBox(height: 6),
        Row(children: [
          _sourceButton('計算値', 'RPM/速度 逆算', GearSource.calculated, source),
          const SizedBox(width: 6),
          _sourceButton('TCU値', 'TCU選択檔位', GearSource.obdPid, source),
        ]),
        const SizedBox(height: 10),
        if (source == GearSource.calculated) ...[
            // ── 齿轮比列表 ──
            Text('変速機ギア比 (最大10速)', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.5))),
            const SizedBox(height: 4),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (int i = 0; i < ratios.length; i++)
                GestureDetector(
                  onTap: () => _editGearRatio(i, ratios[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _cyan.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: _cyan.withOpacity(0.15))),
                    child: Text('${i + 1}速: ${ratios[i].toStringAsFixed(3)}',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                        fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.8))))),
              if (ratios.length < 10)
                GestureDetector(
                  onTap: () {
                    final newRatios = List<double>.of(ratios)..add(0.500);
                    HudChannelStore.setGearConfig(gearRatios: newRatios);
                    setState(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: _cyan.withOpacity(0.2), style: BorderStyle.solid)),
                    child: Text('+ 追加', style: TextStyle(fontFamily: 'monospace',
                      fontSize: 9, fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.4))))),
            ]),
            const SizedBox(height: 10),
            // ── 最终传动比 ──
            _gearInputRow('最終減速比', fd.toStringAsFixed(3), (s) {
              final v = double.tryParse(s);
              if (v != null && v > 0) { HudChannelStore.setGearConfig(finalDrive: v); setState(() {}); }
            }),
            const SizedBox(height: 6),
            // ── 轮胎尺寸 ──
            Text('タイヤ寸法', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.5))),
            const SizedBox(height: 4),
            Row(children: [
              _tirePartInput('幅', '$tw', (s) {
                final v = int.tryParse(s);
                if (v != null && v > 0) { HudChannelStore.setGearConfig(tireWidth: v); setState(() {}); }
              }),
              Text(' / ', style: TextStyle(fontFamily: 'monospace', fontSize: 12,
                fontWeight: FontWeight.w900, color: _cyan.withOpacity(0.3))),
              _tirePartInput('扁平', '$ta', (s) {
                final v = int.tryParse(s);
                if (v != null && v > 0) { HudChannelStore.setGearConfig(tireAspect: v); setState(() {}); }
              }),
              Text(' R', style: TextStyle(fontFamily: 'monospace', fontSize: 12,
                fontWeight: FontWeight.w900, color: _cyan.withOpacity(0.3))),
              _tirePartInput('径', '$tr', (s) {
                final v = int.tryParse(s);
                if (v != null && v > 0) { HudChannelStore.setGearConfig(tireRim: v); setState(() {}); }
              }),
            ]),
            const SizedBox(height: 6),
            Text('外径: ${dMm.toStringAsFixed(1)} mm  周長: ${(dMm * 3.14159265 / 1000).toStringAsFixed(3)} m',
              style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                fontWeight: FontWeight.w700, color: DS.textDim)),
            const SizedBox(height: 4),
            Text('速度=0 → 出撃待命', style: TextStyle(fontFamily: 'monospace',
              fontSize: 7, fontWeight: FontWeight.w600, color: _cyan.withOpacity(0.3))),
          ] else ...[
            // ── TCU DID 选択 ──
            Text('TCU DID選択', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w800, color: _green.withOpacity(0.5))),
            const SizedBox(height: 4),
            for (final gearPid in ObdPids.gearPids)
              _gearDidOption(gearPid),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: _green.withOpacity(0.04),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _green.withOpacity(0.15))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('档位表示ルール (標準化済み)',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                    fontWeight: FontWeight.w800, color: _green.withOpacity(0.7))),
                const SizedBox(height: 4),
                Text('P/N → 出撃待命  |  D1~D9 (停車) → 予備\nR → REVERSE  |  D1~D9 (走行) → 数字档位',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7.5,
                    fontWeight: FontWeight.w600, color: _green.withOpacity(0.45))),
              ])),
          ],
      ]));
  }

  // ── 辅助组件 ──

  Widget _gearDidOption(ObdPid pid) {
    final sel = pid.id == HudChannelStore.selectedGearPidId;
    final mapping = pid.gearMapping;
    return Padding(padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: () {
          HudChannelStore.setSelectedGearPid(pid.id);
          setState(() {});
          widget.onChanged?.call();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: sel ? _green.withOpacity(0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: sel ? _green.withOpacity(0.4) : DS.border)),
          child: Row(children: [
            Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
              color: sel ? _green : DS.textDim, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${pid.shortName}  DID 0x${pid.udsDid}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                  fontWeight: FontWeight.w800, color: sel ? _green : DS.textDim)),
              if (mapping != null)
                Text('${mapping.description} | ${mapping.maxForwardGear}速',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w600,
                    color: (sel ? _green : DS.textDim).withOpacity(0.5))),
            ])),
            if (sel)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: _green.withOpacity(0.1)),
                child: Text('ACTIVE', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 6, fontWeight: FontWeight.w900,
                  color: _green.withOpacity(0.7)))),
          ]))));
  }

  Widget _sourceButton(String label, String sub, GearSource value, GearSource current) {
    final sel = value == current;
    final c = value == GearSource.obdPid ? _green : _cyan;
    return Expanded(child: GestureDetector(
      onTap: () {
        HudChannelStore.setGearConfig(gearSource: value);
        setState(() {});
        widget.onChanged?.call();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? c.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: sel ? c.withOpacity(0.4) : DS.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
              color: sel ? c : DS.textDim, size: 14),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontFamily: 'monospace', fontSize: 10,
              fontWeight: FontWeight.w800, color: sel ? c : DS.textDim)),
          ]),
          Padding(padding: const EdgeInsets.only(left: 20),
            child: Text(sub, style: TextStyle(fontFamily: 'monospace', fontSize: 7,
              fontWeight: FontWeight.w600, color: (sel ? c : DS.textDim).withOpacity(0.5)))),
        ]))));
  }

  void _editGearRatio(int index, double current) {
    final ratios = List<double>.of(HudChannelStore.gearRatios);
    showEvaEditDialog(context, '${index + 1}速 ギア比', current.toStringAsFixed(3), (s) {
      final v = double.tryParse(s);
      if (v != null && v > 0) {
        ratios[index] = v;
        HudChannelStore.setGearConfig(gearRatios: ratios);
        setState(() {});
      }
    }, onDelete: ratios.length > 1 ? () {
      ratios.removeAt(index);
      HudChannelStore.setGearConfig(gearRatios: ratios);
      setState(() {});
    } : null);
  }

  Widget _gearInputRow(String label, String value, ValueChanged<String> onDone) {
    return Row(children: [
      SizedBox(width: 80, child: Text(label, style: TextStyle(fontFamily: 'monospace',
        fontSize: 9, fontWeight: FontWeight.w800, color: _cyan.withOpacity(0.5)))),
      SizedBox(width: 80, child: GestureDetector(
        onTap: () => showEvaEditDialog(context, label, value, onDone),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _cyan.withOpacity(0.06),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _cyan.withOpacity(0.15))),
          child: Text(value, style: TextStyle(fontFamily: 'monospace',
            fontSize: 11, fontWeight: FontWeight.w900, color: _cyan))))),
    ]);
  }

  Widget _tirePartInput(String hint, String value, ValueChanged<String> onDone) {
    return Expanded(child: GestureDetector(
      onTap: () => showEvaEditDialog(context, hint, value, onDone),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: _cyan.withOpacity(0.06),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _cyan.withOpacity(0.15))),
        child: Column(children: [
          Text(hint, style: TextStyle(fontFamily: 'monospace', fontSize: 6,
            fontWeight: FontWeight.w600, color: _cyan.withOpacity(0.3))),
          Text(value, style: TextStyle(fontFamily: 'monospace', fontSize: 12,
            fontWeight: FontWeight.w900, color: _cyan)),
        ]))));
  }
}