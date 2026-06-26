// ════════════════════════════════════════════════════════════════
// rpm_config_card.dart — RPM 配置卡片
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../theme/eva_theme.dart';

class RpmConfigCard extends StatefulWidget {
  const RpmConfigCard({super.key});
  @override State<RpmConfigCard> createState() => _RpmConfigCardState();
}

class _RpmConfigCardState extends State<RpmConfigCard> {
  @override
  Widget build(BuildContext context) {
    final rpmMax = HudChannelStore.rpmMax;
    final shiftRpm = HudChannelStore.shiftRpm;
    return EvaCard(title: 'RPM CONFIG', subtitle: '回転数設定',
      child: Column(children: [
        _rpmSlider('RPM 上限', rpmMax, 4000, 12000, evaAmber, (v) {
          HudChannelStore.setRpmConfig(rpmMax: v); setState(() {}); }),
        const SizedBox(height: 4),
        _rpmSlider('升档提示', shiftRpm.clamp(2000, rpmMax), 2000, rpmMax, evaRed, (v) {
          HudChannelStore.setRpmConfig(shiftRpm: v); setState(() {}); }),
        Padding(padding: const EdgeInsets.only(top: 4),
          child: Text('SHIFT @ ${(shiftRpm / rpmMax * 100).round()}% of REDLINE',
            style: TextStyle(fontFamily: 'monospace', fontSize: 8,
              fontWeight: FontWeight.w700, color: DS.textDim))),
      ]));
  }

  Widget _rpmSlider(String label, double value, double min, double max, Color c, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 70, child: Text(label, style: TextStyle(fontFamily: 'monospace',
        fontSize: 10, fontWeight: FontWeight.w800, color: c.withOpacity(0.7)))),
      Expanded(child: SliderTheme(
        data: SliderThemeData(activeTrackColor: c, inactiveTrackColor: c.withOpacity(0.1),
          thumbColor: c, overlayColor: c.withOpacity(0.1), trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
        child: Slider(value: value, min: min, max: max,
          divisions: ((max - min) / 250).round().clamp(1, 100),
          onChanged: onChanged))),
      SizedBox(width: 50, child: Text('${value.round()}', textAlign: TextAlign.right,
        style: TextStyle(fontFamily: 'monospace', fontSize: 13,
          fontWeight: FontWeight.w900, color: c))),
    ]);
  }
}
