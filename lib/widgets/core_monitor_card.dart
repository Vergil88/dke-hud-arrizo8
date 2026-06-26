// ════════════════════════════════════════════════════════════════
// core_monitor_card.dart — 基幹監視卡片
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../theme/eva_theme.dart';

class CoreMonitorCard extends StatelessWidget {
  const CoreMonitorCard({super.key});

  @override
  Widget build(BuildContext context) {
    final pids = HudChannelStore.corePidIds;
    final categories = <String, List<String>>{
      'RPM // 回転数': pids.where((p) => p.contains('rpm')).toList(),
      'SPEED // 車速': pids.where((p) => p.contains('speed')).toList(),
      'ACCEL // 油門': pids.where((p) =>
        p.contains('throttle') || p.contains('accel')).toList(),
      'GEAR // 档位': pids.where((p) => p.contains('gear')).toList(),
    };
    return EvaCard(
      title: 'CORE MONITOR',
      subtitle: '基幹監視 — 常時輪詢',
      trailing: Icon(Icons.lock_outline, color: DS.textDim, size: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('独立警報 (升档 / 全力全開) 及 HUD 基本表示所需',
          style: TextStyle(fontFamily: 'monospace', fontSize: 7,
            fontWeight: FontWeight.w600, color: DS.textDim)),
        const SizedBox(height: 8),
        for (final entry in categories.entries)
          if (entry.value.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Icon(Icons.sensors, color: evaAmber.withOpacity(0.5), size: 12),
                const SizedBox(width: 6),
                SizedBox(width: 80, child: Text(entry.key,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                    fontWeight: FontWeight.w800, color: evaAmber.withOpacity(0.7)))),
                Expanded(child: Text(entry.value.join(', '),
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w600, color: DS.textDim),
                  overflow: TextOverflow.ellipsis)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: const Color(0xFF76FF03).withOpacity(0.1)),
                  child: Text('LIVE', style: TextStyle(fontFamily: 'monospace',
                    fontSize: 6, fontWeight: FontWeight.w900,
                    color: const Color(0xFF76FF03).withOpacity(0.7)))),
              ])),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: DS.border), borderRadius: BorderRadius.circular(3)),
          child: Row(children: [
            Icon(Icons.info_outline, color: DS.textDim, size: 10),
            const SizedBox(width: 6),
            Expanded(child: Text('これらの PID はユーザー通道に関わらず常時輪詢されます',
              style: TextStyle(fontFamily: 'monospace', fontSize: 6.5,
                fontWeight: FontWeight.w600, color: DS.textDim))),
          ])),
      ]));
  }
}
