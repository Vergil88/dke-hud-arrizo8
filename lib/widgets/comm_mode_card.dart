// ════════════════════════════════════════════════════════════════
// comm_mode_card.dart — 通讯模式切换卡片
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models/obd_pids.dart';
import '../services/bt_manager.dart';
import '../services/dke_logger.dart';
import '../theme/eva_theme.dart';

class CommModeCard extends StatefulWidget {
  final VoidCallback onChanged;
  const CommModeCard({super.key, required this.onChanged});

  @override
  State<CommModeCard> createState() => _CommModeCardState();
}

class _CommModeCardState extends State<CommModeCard> {
  Future<void> _setMode(CommMode newMode) async {
    final bt = BtManager.instance;
    if (bt.isConnected) return;
    final oldMode = bt.commMode;
    bt.commMode = newMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kCommMode, newMode.index);
    DkeLogger.instance.write('SYS', '模式切换: ${oldMode.name} → ${newMode.name}');
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final mode = BtManager.instance.commMode;
    final isObd2 = mode == CommMode.obd2;
    final connected = BtManager.instance.isConnected;
    final modeColor = isObd2 ? evaCyan : evaAmber;
    final modeDesc = isObd2
        ? '奇瑞艾瑞泽8 2.0T / 标准OBD-II Mode01 / ISO 15765-4'
        : 'Mercedes AMG W205 C63 / C190 GT / 强化UDS超高速采样';

    return EvaCard(
      title: 'COMM PROTOCOL',
      subtitle: '通信プロトコル',
      trailing: connected
          ? Icon(Icons.lock, size: 14, color: evaRed.withOpacity(0.6))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ★ 醒目的双模式切换开关
        Container(
          decoration: BoxDecoration(
            color: DS.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DS.border),
          ),
          child: Row(children: [
            // UDS 按钮
            Expanded(
              child: GestureDetector(
                onTap: connected ? null : () => _setMode(CommMode.uds),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: !isObd2 ? evaAmber.withOpacity(0.15) : Colors.transparent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(7),
                      bottomLeft: Radius.circular(7),
                    ),
                    border: !isObd2
                        ? Border.all(color: evaAmber.withOpacity(0.5))
                        : null,
                  ),
                  child: Column(children: [
                    Text('UDS', style: TextStyle(
                      fontFamily: 'monospace', fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: !isObd2 ? evaAmber : DS.textDim,
                    )),
                    const SizedBox(height: 2),
                    Text('Mercedes AMG', style: TextStyle(
                      fontFamily: 'monospace', fontSize: 7,
                      fontWeight: FontWeight.w600,
                      color: !isObd2 ? evaAmber.withOpacity(0.6) : DS.textDim.withOpacity(0.5),
                    )),
                  ]),
                ),
              ),
            ),
            // OBD-II 按钮
            Expanded(
              child: GestureDetector(
                onTap: connected ? null : () => _setMode(CommMode.obd2),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isObd2 ? evaCyan.withOpacity(0.15) : Colors.transparent,
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(7),
                      bottomRight: Radius.circular(7),
                    ),
                    border: isObd2
                        ? Border.all(color: evaCyan.withOpacity(0.5))
                        : null,
                  ),
                  child: Column(children: [
                    Text('OBD-II', style: TextStyle(
                      fontFamily: 'monospace', fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: isObd2 ? evaCyan : DS.textDim,
                    )),
                    const SizedBox(height: 2),
                    Text('Arrizo 8 2.0T', style: TextStyle(
                      fontFamily: 'monospace', fontSize: 7,
                      fontWeight: FontWeight.w600,
                      color: isObd2 ? evaCyan.withOpacity(0.6) : DS.textDim.withOpacity(0.5),
                    )),
                  ]),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        // 当前模式描述
        Text(modeDesc, style: TextStyle(
          fontFamily: 'monospace', fontSize: 7,
          fontWeight: FontWeight.w700,
          color: modeColor.withOpacity(0.5),
        )),
        // 连接中提示
        if (connected) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.warning_amber, size: 12, color: evaRed.withOpacity(0.6)),
            const SizedBox(width: 4),
            Text('⚠ 切换模式需要先断开连接', style: TextStyle(
              fontFamily: 'monospace', fontSize: 8,
              fontWeight: FontWeight.w700,
              color: evaRed.withOpacity(0.6),
            )),
          ]),
        ],
      ]),
    );
  }
}
