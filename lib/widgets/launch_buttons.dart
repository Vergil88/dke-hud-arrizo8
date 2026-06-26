// ════════════════════════════════════════════════════════════════
// launch_buttons.dart — HUD 启动按钮
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../main.dart';
import '../services/bt_manager.dart';
import '../screens/hud_shared.dart';
import '../theme/eva_theme.dart';

class LaunchButtons extends StatelessWidget {
  final void Function(bool demo) onLaunch;

  const LaunchButtons({super.key, required this.onLaunch});

  @override
  Widget build(BuildContext context) {
    final connected = BtManager.instance.isConnected;
    return Column(children: [
      _launchBtn('DEMO 起動', cOrange, true),
      const SizedBox(height: 10),
      _launchBtn('実車接続 起動', connected ? evaGreen : DS.textDim, connected),
      if (!connected) Padding(padding: const EdgeInsets.only(top: 6),
        child: Text('需要蓝牙连接', style: TextStyle(fontFamily: 'monospace',
          fontSize: 9, fontWeight: FontWeight.w700, color: DS.textDim))),
    ]);
  }

  Widget _launchBtn(String label, Color co, bool enabled) {
    return GestureDetector(
      onTap: enabled ? () => onLaunch(label.contains('DEMO')) : null,
      child: Container(width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: enabled ? co.withOpacity(0.1) : DS.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: enabled ? co.withOpacity(0.4) : DS.border, width: 1.5)),
        child: Center(child: Text(label, style: TextStyle(fontFamily: 'monospace',
          fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2,
          color: enabled ? co : DS.textDim)))));
  }
}
