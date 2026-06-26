// ════════════════════════════════════════════════════════════════
// channel_editor_sheet.dart — 通道编辑器 BottomSheet
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../models/obd_pids.dart';
import '../services/bt_manager.dart';
import '../screens/hud_sfx.dart';
import '../theme/eva_theme.dart';

class ChannelEditorSheet extends StatefulWidget {
  final HudSlot slot;
  final VoidCallback onSaved;

  const ChannelEditorSheet({super.key, required this.slot, required this.onSaved});
  @override State<ChannelEditorSheet> createState() => _ChannelEditorSheetState();
}

class _ChannelEditorSheetState extends State<ChannelEditorSheet> {
  late String label, jpLabel, selectedPid, unitOverride;
  late double cautionHigh, dangerHigh, cautionLow, dangerLow, gaugeMax;
  late int warnIdx, alertStyleIdx;
  late String alertSfxId, alertTitleJp, alertTitleEn;
  late bool alertBrightness;
  String? guardPidId;
  late double guardMinValue;

  late final TextEditingController labelCtrl, jpLabelCtrl,
      cautionHighCtrl, dangerHighCtrl, cautionLowCtrl, dangerLowCtrl, unitCtrl,
      alertTitleJpCtrl, alertTitleEnCtrl;

  @override
  void initState() {
    super.initState();
    final config = HudChannelStore.get(widget.slot);
    label = config.label;
    jpLabel = config.jpLabel;
    selectedPid = config.pidId;
    cautionHigh = config.cautionHigh;
    dangerHigh = config.dangerHigh;
    cautionLow = config.cautionLow;
    dangerLow = config.dangerLow;
    gaugeMax = config.gaugeMax;
    unitOverride = config.unitOverride;
    warnIdx = config.warnDirection.index;
    alertStyleIdx = config.alertStyle.index;
    alertSfxId = config.alertSfxId;
    alertTitleJp = config.alertTitleJp;
    alertTitleEn = config.alertTitleEn;
    alertBrightness = config.alertBoostBrightness;
    guardPidId = config.alertGuardPidId;
    guardMinValue = config.alertGuardMinValue;

    labelCtrl = TextEditingController(text: label);
    jpLabelCtrl = TextEditingController(text: jpLabel);
    cautionHighCtrl = TextEditingController(text: cautionHigh.toString());
    dangerHighCtrl = TextEditingController(text: dangerHigh.toString());
    cautionLowCtrl = TextEditingController(text: cautionLow.toString());
    dangerLowCtrl = TextEditingController(text: dangerLow.toString());
    unitCtrl = TextEditingController(text: unitOverride);
    alertTitleJpCtrl = TextEditingController(text: alertTitleJp);
    alertTitleEnCtrl = TextEditingController(text: alertTitleEn);
  }

  @override
  void dispose() {
    labelCtrl.dispose(); jpLabelCtrl.dispose();
    cautionHighCtrl.dispose(); dangerHighCtrl.dispose();
    cautionLowCtrl.dispose(); dangerLowCtrl.dispose();
    unitCtrl.dispose(); alertTitleJpCtrl.dispose(); alertTitleEnCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await HudChannelStore.set(widget.slot, ChannelConfig(
      label: label, jpLabel: jpLabel, pidId: selectedPid,
      cautionHigh: cautionHigh, dangerHigh: dangerHigh,
      cautionLow: cautionLow, dangerLow: dangerLow,
      gaugeMax: gaugeMax, warnDirection: WarnDirection.values[warnIdx],
      unitOverride: unitOverride,
      alertStyle: AlertStyle.values[alertStyleIdx],
      alertSfxId: alertSfxId,
      alertTitleJp: alertTitleJp,
      alertTitleEn: alertTitleEn,
      alertBoostBrightness: alertBrightness,
      alertGuardPidId: guardPidId,
      alertGuardMinValue: guardMinValue));
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final showHigh = warnIdx == 0 || warnIdx == 2;
    final showLow  = warnIdx == 1 || warnIdx == 2;
    return DraggableScrollableSheet(
      initialChildSize: 0.75, minChildSize: 0.4, maxChildSize: 0.9, expand: false,
      builder: (_, scrollCtrl) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4, decoration: BoxDecoration(
            color: DS.borderHi, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          // ── 标题栏 ──
          Row(children: [
            Text('CH${widget.slot.index + 1} // $label', style: TextStyle(fontFamily: 'monospace',
              fontSize: 16, fontWeight: FontWeight.w900, color: evaAmber)),
            const Spacer(),
            GestureDetector(
              onTap: _save,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: evaGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: evaGreen.withOpacity(0.3))),
                child: Text('保存', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 11, fontWeight: FontWeight.w800, color: evaGreen)))),
          ]),
          const SizedBox(height: 16),
          // ── 表单内容 ──
          Expanded(child: ListView(controller: scrollCtrl, children: [
            evaInputRow('LABEL', labelCtrl, (v) { label = v; }),
            evaInputRow('JP LABEL', jpLabelCtrl, (v) { jpLabel = v; }),
            Padding(padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text('DATA SOURCE // データソース', style: TextStyle(fontFamily: 'monospace',
                fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1,
                color: evaAmber.withOpacity(0.5)))),
            // ★ PID 列表
            ...ObdPids.selectableFor(BtManager.instance.commMode).map((pid) {
              final sel = pid.id == selectedPid;
              return GestureDetector(
                onTap: () => setState(() => selectedPid = pid.id),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: sel ? evaAmber.withOpacity(0.08) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: sel ? evaAmber.withOpacity(0.4) : DS.border.withOpacity(0.3))),
                  child: Row(children: [
                    Icon(sel ? Icons.check_circle : Icons.radio_button_off,
                      size: 14, color: sel ? evaAmber : DS.textDim),
                    const SizedBox(width: 8),
                    Text(pid.id, style: TextStyle(fontFamily: 'monospace', fontSize: 10,
                      fontWeight: FontWeight.w700, color: sel ? evaAmber : DS.textSec)),
                    const Spacer(),
                    Text('${pid.shortName} (${pid.unit})', style: TextStyle(fontFamily: 'monospace',
                      fontSize: 8, fontWeight: FontWeight.w700, color: DS.textDim)),
                  ])));
            }),
            // ── 警告方向 ──
            Padding(padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Text('WARN DIRECTION', style: TextStyle(fontFamily: 'monospace',
                fontSize: 9, fontWeight: FontWeight.w800, color: evaAmber.withOpacity(0.5)))),
            Row(children: List.generate(3, (j) {
              final labels = ['▲ 上限', '▼ 下限', '▲▼ 双向'];
              final sel = j == warnIdx;
              return Expanded(child: GestureDetector(
                onTap: () => setState(() => warnIdx = j),
                child: Container(
                  margin: EdgeInsets.only(right: j < 2 ? 6 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? evaAmber.withOpacity(0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: sel ? evaAmber.withOpacity(0.5) : DS.border)),
                  child: Center(child: Text(labels[j], style: TextStyle(fontFamily: 'monospace',
                    fontSize: 10, fontWeight: FontWeight.w800,
                    color: sel ? evaAmber : DS.textDim))))));
            })),
            // ── 阈值输入 ──
            if (showHigh) ...[
              const SizedBox(height: 12),
              evaThresholdLabel('CAUTION HIGH ▲', const Color(0xFFFFDD00)),
              evaNumInput(cautionHighCtrl, (v) { cautionHigh = v; }),
              const SizedBox(height: 8),
              evaThresholdLabel('DANGER HIGH ▲', evaRed),
              evaNumInput(dangerHighCtrl, (v) { dangerHigh = v; }),
            ],
            if (showLow) ...[
              const SizedBox(height: 12),
              evaThresholdLabel('CAUTION LOW ▼', const Color(0xFF40C4FF)),
              evaNumInput(cautionLowCtrl, (v) { cautionLow = v; }),
              const SizedBox(height: 8),
              evaThresholdLabel('DANGER LOW ▼', const Color(0xFFFF6E40)),
              evaNumInput(dangerLowCtrl, (v) { dangerLow = v; }),
            ],
            const SizedBox(height: 12),
            evaInputRow('UNIT OVERRIDE', unitCtrl, (v) { unitOverride = v; }),
            // ════════════════════════════════════════
            // ★ 警报配置
            // ════════════════════════════════════════
            Padding(padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text('ALERT CONFIG // 警報設定', style: TextStyle(fontFamily: 'monospace',
                fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1,
                color: evaRed.withOpacity(0.7)))),
            // 警报风格
            Text('ALERT STYLE', style: TextStyle(fontFamily: 'monospace',
              fontSize: 9, fontWeight: FontWeight.w800, color: evaRed.withOpacity(0.5))),
            const SizedBox(height: 4),
            Row(children: List.generate(AlertStyle.values.length, (j) {
              final labels = ['OFF', 'OVERHEAT', 'EMERG', 'BOOST', 'FUEL', 'AFR', 'GENERIC'];
              final sel = j == alertStyleIdx;
              return Expanded(child: GestureDetector(
                onTap: () => setState(() => alertStyleIdx = j),
                child: Container(
                  margin: EdgeInsets.only(right: j < 6 ? 3 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: sel ? evaRed.withOpacity(0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: sel ? evaRed.withOpacity(0.5) : DS.border)),
                  child: Center(child: Text(labels[j], style: TextStyle(fontFamily: 'monospace',
                    fontSize: 7, fontWeight: FontWeight.w800,
                    color: sel ? evaRed : DS.textDim))))));
            })),
            const SizedBox(height: 10),
            // 音效选择
            Text('ALERT SFX // 警報音効', style: TextStyle(fontFamily: 'monospace',
              fontSize: 9, fontWeight: FontWeight.w800, color: evaRed.withOpacity(0.5))),
            const SizedBox(height: 4),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final sid in HudSfx.selectableIds)
                GestureDetector(
                  onTap: () {
                    setState(() => alertSfxId = sid);
                    if (sid != 'none') HudSfx.instance.play(sid);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: alertSfxId == sid ? evaRed.withOpacity(0.1) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: alertSfxId == sid ? evaRed.withOpacity(0.5) : DS.border)),
                    child: Text(HudSfx.displayNameOf(sid), style: TextStyle(fontFamily: 'monospace',
                      fontSize: 8, fontWeight: FontWeight.w700,
                      color: alertSfxId == sid ? evaRed : DS.textDim)))),
            ]),
            const SizedBox(height: 10),
            // 叠层标题
            evaInputRow('ALERT TITLE (JP)', alertTitleJpCtrl,
              (v) { alertTitleJp = v; }),
            evaInputRow('ALERT TITLE (EN)', alertTitleEnCtrl,
              (v) { alertTitleEn = v; }),
            // OLED 亮度
            Row(children: [
              Icon(Icons.brightness_high, size: 14,
                color: alertBrightness ? evaRed : DS.textDim),
              const SizedBox(width: 8),
              Expanded(child: Text('OLED BRIGHTNESS BOOST',
                style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: alertBrightness ? evaRed.withOpacity(0.8) : DS.textDim))),
              SizedBox(height: 28, child: Switch.adaptive(
                value: alertBrightness, activeColor: evaRed,
                onChanged: (v) => setState(() => alertBrightness = v))),
            ]),
            const SizedBox(height: 14),
            // ★ 守衛条件
            _guardConditionSection(),
            const SizedBox(height: 24),
          ])),
        ]))));
  }

  // ── 守衛条件区块 ──

  Widget _guardConditionSection() {
    const gGreen = Color(0xFF76FF03);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: DS.border), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(guardPidId != null ? Icons.shield : Icons.shield_outlined,
            color: guardPidId != null ? gGreen : DS.textDim, size: 14),
          const SizedBox(width: 6),
          Text('GUARD CONDITION // 守衛条件', style: TextStyle(fontFamily: 'monospace',
            fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 2,
            color: guardPidId != null ? gGreen.withOpacity(0.8) : DS.textDim)),
        ]),
        const SizedBox(height: 6),
        Text('第二 PID が閾値以上の時のみ警報発動', style: TextStyle(fontFamily: 'monospace',
          fontSize: 7, fontWeight: FontWeight.w600, color: DS.textDim)),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(width: 55, child: Text('PID:', style: TextStyle(fontFamily: 'monospace',
            fontSize: 9, fontWeight: FontWeight.w800, color: DS.textDim))),
          Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: [
              _guardPidChip('OFF', null),
              _guardPidChip('uds_accel', 'uds_accel'),
              _guardPidChip('uds_load', 'uds_load'),
            ]))),
        ]),
        if (guardPidId != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            SizedBox(width: 55, child: Text('MIN:', style: TextStyle(fontFamily: 'monospace',
              fontSize: 9, fontWeight: FontWeight.w800, color: DS.textDim))),
            Expanded(child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: gGreen,
                inactiveTrackColor: gGreen.withOpacity(0.1),
                thumbColor: gGreen,
                overlayColor: gGreen.withOpacity(0.1),
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
              child: Slider(value: guardMinValue.clamp(0, 100), min: 0, max: 100,
                divisions: 20,
                onChanged: (v) => setState(() => guardMinValue = v)))),
            SizedBox(width: 40, child: Text('${guardMinValue.round()}%', textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'monospace', fontSize: 11,
                fontWeight: FontWeight.w900, color: gGreen))),
          ]),
        ],
      ]));
  }

  Widget _guardPidChip(String label, String? value) {
    final sel = guardPidId == value;
    const gGreen = Color(0xFF76FF03);
    return GestureDetector(
      onTap: () => setState(() => guardPidId = value),
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? gGreen.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: sel ? gGreen.withOpacity(0.5) : DS.border)),
        child: Text(label, style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w800,
          color: sel ? gGreen : DS.textDim))));
  }
}
