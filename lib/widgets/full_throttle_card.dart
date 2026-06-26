// ════════════════════════════════════════════════════════════════
// full_throttle_card.dart — 全力全開警報配置
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../screens/hud_sfx.dart';
import '../theme/eva_theme.dart';

class FullThrottleCard extends StatefulWidget {
  const FullThrottleCard({super.key});
  @override State<FullThrottleCard> createState() => _FullThrottleCardState();
}

class _FullThrottleCardState extends State<FullThrottleCard> {
  static const _gold = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    final enabled = HudChannelStore.fullThrottleEnabled;
    final threshold = HudChannelStore.fullThrottleThreshold;
    return EvaCard(title: 'FULL THROTTLE', subtitle: '全力全開警報',
      child: Column(children: [
        Row(children: [
          Icon(enabled ? Icons.flash_on : Icons.flash_off,
            color: enabled ? _gold : DS.textDim, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(enabled ? '全力全開警報 — ON' : '全力全開警報 — OFF',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11,
              fontWeight: FontWeight.w700,
              color: enabled ? _gold.withOpacity(0.8) : DS.textDim))),
          SizedBox(height: 28, child: Switch.adaptive(
            value: enabled, activeColor: _gold,
            onChanged: (v) {
              HudChannelStore.setFullThrottleConfig(enabled: v);
              setState(() {});
            })),
        ]),
        if (enabled) ...[
          const SizedBox(height: 8),
          Row(children: [
            SizedBox(width: 70, child: Text('発動閾値', style: TextStyle(fontFamily: 'monospace',
              fontSize: 10, fontWeight: FontWeight.w800, color: _gold.withOpacity(0.7)))),
            Expanded(child: SliderTheme(
              data: SliderThemeData(activeTrackColor: _gold, inactiveTrackColor: _gold.withOpacity(0.1),
                thumbColor: _gold, overlayColor: _gold.withOpacity(0.1), trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
              child: Slider(value: threshold, min: 60, max: 100,
                onChanged: (v) {
                  HudChannelStore.setFullThrottleConfig(threshold: v);
                  setState(() {});
                }))),
            SizedBox(width: 50, child: Text('${threshold.round()}%', textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'monospace', fontSize: 13,
                fontWeight: FontWeight.w900, color: _gold))),
          ]),
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text('THROTTLE ≥ ${threshold.round()}% → 全力全開発動',
              style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                fontWeight: FontWeight.w700, color: DS.textDim))),
          const SizedBox(height: 6),
          evaMiniBtn('▶ 全力全開', () => HudSfx.instance.playFullThrottle()),
        ],
      ]));
  }
}
