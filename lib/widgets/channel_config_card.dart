// ════════════════════════════════════════════════════════════════
// channel_config_card.dart — 通道配置卡片（列表）
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../models/hud_channel_config.dart';
import '../theme/eva_theme.dart';
import 'channel_editor_sheet.dart';

class ChannelConfigCard extends StatefulWidget {
  const ChannelConfigCard({super.key});
  @override State<ChannelConfigCard> createState() => _ChannelConfigCardState();
}

class _ChannelConfigCardState extends State<ChannelConfigCard> {

  void _showEditor(HudSlot slot) {
    showModalBottomSheet(
      context: context, backgroundColor: DS.surface, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => ChannelEditorSheet(
        slot: slot,
        onSaved: () { if (mounted) setState(() {}); },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return EvaCard(
      title: 'DATA CHANNELS', subtitle: 'データ設定',
      trailing: GestureDetector(
        onTap: () async { await HudChannelStore.resetDefaults(); if (mounted) setState(() {}); },
        child: Text('重置默认', style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w800, color: evaRed.withOpacity(0.5)))),
      child: Column(children: [
        ...HudSlot.values.map((slot) => _channelRow(slot)),
      ]));
  }

  Widget _channelRow(HudSlot slot) {
    final config = HudChannelStore.get(slot);
    final shortName = HudChannelStore.paramShortName(config.pidId);
    return GestureDetector(
      onTap: () => _showEditor(slot),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: evaAmber.withOpacity(0.02),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: evaAmber.withOpacity(0.08))),
        child: Row(children: [
          SizedBox(width: 60, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(config.label, style: TextStyle(fontFamily: 'monospace',
              fontSize: 11, fontWeight: FontWeight.w900, color: evaAmber)),
            if (config.jpLabel.isNotEmpty)
              Text(config.jpLabel, style: TextStyle(fontFamily: 'monospace',
                fontSize: 7, fontWeight: FontWeight.w600, color: evaAmber.withOpacity(0.3))),
          ])),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(shortName, style: TextStyle(fontFamily: 'monospace',
              fontSize: 9, fontWeight: FontWeight.w700, color: DS.textSec)),
            Text(_thresholdSummary(config), style: TextStyle(fontFamily: 'monospace',
              fontSize: 7, fontWeight: FontWeight.w700, color: DS.textDim)),
          ])),
          Icon(Icons.edit, size: 14, color: evaAmber.withOpacity(0.3)),
        ])));
  }

  String _thresholdSummary(ChannelConfig c) {
    final th = switch (c.warnDirection) {
      WarnDirection.high  => '▲ C:${c.cautionHigh} D:${c.dangerHigh} ${c.unit}',
      WarnDirection.low   => '▼ C:${c.cautionLow} D:${c.dangerLow} ${c.unit}',
      WarnDirection.both  => '▲${c.cautionHigh}/${c.dangerHigh} ▼${c.cautionLow}/${c.dangerLow} ${c.unit}',
    };
    if (c.alertStyle != AlertStyle.none) {
      final guard = c.alertGuardPidId != null ? ' 🛡${c.alertGuardMinValue.round()}%' : '';
      return '$th  🔔${c.alertStyle.name}$guard';
    }
    return th;
  }
}
