// ════════════════════════════════════════════════════════════════
// bt_connection_card.dart — 蓝牙接続卡片
// ════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../services/bt_manager.dart';
import '../services/obd_transport.dart';
import '../theme/eva_theme.dart';

class BtConnectionCard extends StatefulWidget {
  const BtConnectionCard({super.key});
  @override State<BtConnectionCard> createState() => _BtConnectionCardState();
}

class _BtConnectionCardState extends State<BtConnectionCard> {
  bool _btScanning = false;
  bool _btConnecting = false;
  String _btStatus = '未連接';

  bool _diagRunning = false;
  bool _enduranceRunning = false;
  final List<String> _diagLog = [];

  // ── EVA 同步率 ──
  double _syncRate = 0;
  String _syncLabel = '';

  @override
  void initState() {
    super.initState();
    BtManager.instance.addListener(_onBtChanged);
    BtManager.instance.onSyncRate = (rate, label) {
      if (mounted) setState(() { _syncRate = rate; _syncLabel = label; });
    };
    _syncStatus();
  }

  @override
  void dispose() {
    BtManager.instance.removeListener(_onBtChanged);
    BtManager.instance.onSyncRate = null;
    super.dispose();
  }

  void _syncStatus() {
    _btStatus = BtManager.instance.isConnected
        ? '已连接: ${BtManager.instance.deviceName}'
        : '未连接';
  }

  void _onBtChanged() {
    if (!mounted) return;
    setState(() => _syncStatus());
  }

  // ═══ 蓝牙操作 ═══

  Future<void> _scanAndConnect() async {
    if (_btScanning || _btConnecting) return;
    setState(() { _btScanning = true;
      _btStatus = BtManager.instance.linkMode == BtLinkMode.ble
          ? '正在扫描低功耗设备...' : '正在扫描...'; });
    try {
      final ok = await BtManager.ensurePermissions();
      if (!ok) { setState(() { _btScanning = false; _btStatus = '权限被拒绝'; }); return; }
      final enabled = await BtManager.isBluetoothEnabled();
      if (!enabled) {
        final turned = await BtManager.requestEnable();
        if (!turned) {
          if (mounted) {
            setState(() { _btScanning = false;
            _btStatus = Platform.isIOS ? '请在设置中开启蓝牙' : '蓝牙未开启'; });
          }
          return;
        }
      }
      final devs = await BtManager.getDevices();
      if (!mounted) return;
      setState(() => _btScanning = false);
      if (devs.isEmpty) {
        setState(() => _btStatus = BtManager.instance.linkMode == BtLinkMode.ble
            ? '未发现 OBDLink CX (确认车辆已通电)' : '未发现设备');
        return; }
      _showDeviceSheet(devs);
    } catch (e) {
      if (mounted) setState(() { _btScanning = false; _btStatus = '扫描失败: $e'; });
    }
  }

  void _showDeviceSheet(List<OBDDevice> devs) {
    showModalBottomSheet(
      context: context, backgroundColor: DS.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.55;
        return SafeArea(child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Padding(padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 36, height: 4, decoration: BoxDecoration(
                color: DS.borderHi, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              Text(BtManager.instance.linkMode == BtLinkMode.ble
                  ? '选择 BLE 适配器' : '选择 OBD 适配器',
                style: TextStyle(fontFamily: 'monospace',
                  fontSize: 14, fontWeight: FontWeight.w800, color: evaAmber)),
              const SizedBox(height: 12),
              Flexible(child: ListView.builder(
                shrinkWrap: true, itemCount: devs.length,
                itemBuilder: (ctx, i) {
                  final d = devs[i];
                  return Padding(padding: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () { Navigator.pop(ctx); _connectDevice(d); },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(color: DS.surfaceHi,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: evaAmber.withOpacity(0.2))),
                        child: Row(children: [
                          Icon(Icons.bluetooth, color: evaAmber.withOpacity(0.6), size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(d.name, style: const TextStyle(fontFamily: 'monospace',
                                fontSize: 13, fontWeight: FontWeight.w700, color: DS.textPri)),
                              Text(d.address, style: TextStyle(fontFamily: 'monospace',
                                fontSize: 9, color: DS.textDim)),
                            ])),
                          Icon(Icons.chevron_right, color: evaAmber.withOpacity(0.3)),
                        ]))));
                })),
            ]))));
      });
  }

  Future<void> _connectDevice(OBDDevice device) async {
    setState(() { _btConnecting = true; _btStatus = '连接中: ${device.name}...'; });
    try {
      final ok = await BtManager.instance.connect(device);
      if (mounted) {
        setState(() {
        _btConnecting = false;
        _btStatus = ok ? '已连接: ${device.name}' : '连接失败';
      });
      }
    } catch (e) {
      if (mounted) setState(() { _btConnecting = false; _btStatus = '连接失败: $e'; });
    }
  }

  Future<void> _disconnect() async {
    await BtManager.instance.disconnect();
    if (mounted) setState(() { _btStatus = '已断开'; _diagLog.clear(); _syncRate = 0; _syncLabel = ''; });
  }

  Future<void> _runDiag() async {
    if (_diagRunning || !BtManager.instance.isConnected) return;
    setState(() { _diagRunning = true; _diagLog.clear(); _syncRate = 0; _syncLabel = ''; });
    final oldLog = BtManager.instance.onLog;
    BtManager.instance.onLog = (tag, msg) {
      oldLog?.call(tag, msg);
      if (mounted) setState(() => _diagLog.add(msg));
    };
    try {
      await BtManager.instance.runLatencyDiag(rounds: 10);
    } catch (e) {
      if (mounted) setState(() => _diagLog.add('❌ 诊断异常: $e'));
    } finally {
      BtManager.instance.onLog = oldLog;
      if (mounted) setState(() => _diagRunning = false);
    }
  }

  Future<void> _runEndurance() async {
    if (_enduranceRunning || _diagRunning || !BtManager.instance.isConnected) return;
    setState(() { _enduranceRunning = true; _diagLog.clear(); _syncRate = 0; _syncLabel = ''; });
    final oldLog = BtManager.instance.onLog;
    BtManager.instance.onLog = (tag, msg) {
      oldLog?.call(tag, msg);
      if (mounted) setState(() => _diagLog.add(msg));
    };
    try {
      await BtManager.instance.runEnduranceTest(durationSec: 300);
    } catch (e) {
      if (mounted) setState(() => _diagLog.add('❌ 耐久测试异常: $e'));
    } finally {
      BtManager.instance.onLog = oldLog;
      if (mounted) setState(() => _enduranceRunning = false);
    }
  }

  void _stopEndurance() {
    BtManager.instance.stopEndurance();
    if (mounted) setState(() => _enduranceRunning = false);
  }

  Future<void> _setLinkMode(BtLinkMode mode) async {
    if (BtManager.instance.isConnected) {
      await BtManager.instance.disconnect();
    }
    BtManager.instance.linkMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kLinkMode, mode.index);
    if (mounted) setState(() { _btStatus = '未连接'; });
  }

  // ═══ 构建 ═══

  @override
  Widget build(BuildContext context) {
    // ★ HUD 诊断结果: 退出 HUD 后自动显示
    final pendingDiag = BtManager.instance.hudDiagResult;
    if (pendingDiag != null) {
      BtManager.instance.hudDiagResult = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          for (final line in pendingDiag.split('\n')) {
            if (line.trim().isNotEmpty) _diagLog.add(line);
          }
        });
      });
    }

    final connected = BtManager.instance.isConnected;
    final isBle = BtManager.instance.linkMode == BtLinkMode.ble;
    final linkLabel = isBle ? '低功耗' : '经典';
    return EvaCard(
      title: 'BLUETOOTH LINK',
      subtitle: '蓝牙接続',
      trailing: connected
          ? Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: evaGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: evaGreen.withOpacity(0.3))),
              child: Text('LINKED $linkLabel',
                style: TextStyle(fontFamily: 'monospace',
                  fontSize: 8, fontWeight: FontWeight.w900, color: evaGreen)))
          : null,
      child: Column(children: [
        // ★ 链路模式选择
        if (Platform.isAndroid) ...[
          Row(children: [
            _linkModeBtn('SPP高性能 — MX+', BtLinkMode.spp, !isBle),
            const SizedBox(width: 8),
            _linkModeBtn('BLE低功率 — CX', BtLinkMode.ble, isBle),
          ]),
          const SizedBox(height: 4),
          Text(isBle
              ? '「基于OBDLink CX开发: BLE沈黙の神速・極限同調!!」'
              : '「基于OBDLink MX+开发: SPP極限性能・限界突破全解放ッ!!」',
            style: TextStyle(fontFamily: 'monospace', fontSize: 7,
              fontWeight: FontWeight.w700, color: evaCyan.withOpacity(0.35))),
          const SizedBox(height: 8),
        ]
        else if (Platform.isIOS) ...[
          Row(children: [
            Icon(Icons.bluetooth, size: 12, color: evaCyan),
            const SizedBox(width: 6),
            Text('低功耗蓝牙 — BLE OBD设备',
              style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                fontWeight: FontWeight.w800, color: evaCyan.withOpacity(0.7))),
          ]),
          const SizedBox(height: 8),
        ],
        // ★ 状态栏
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: connected ? evaGreen.withOpacity(0.03) : evaAmber.withOpacity(0.02),
            border: Border.all(color: (connected ? evaGreen : evaAmber).withOpacity(0.1))),
          child: Row(children: [
            Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              size: 14, color: connected ? evaGreen : evaDim),
            const SizedBox(width: 8),
            Expanded(child: Text(_btStatus, style: TextStyle(fontFamily: 'monospace',
              fontSize: 10, fontWeight: FontWeight.w700,
              color: connected ? evaGreen : evaAmber.withOpacity(0.6)))),
            if (_btScanning || _btConnecting)
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(
                strokeWidth: 1.5, valueColor: AlwaysStoppedAnimation(evaAmber))),
          ])),
        const SizedBox(height: 8),
        Row(children: [
          if (!connected) Expanded(child: evaActionBtn(
            _btScanning ? '扫描中...' : (isBle ? '扫描 BLE' : '搜索配对设备'),
            isBle ? Icons.bluetooth_searching : Icons.search, evaAmber,
            _btScanning || _btConnecting ? null : _scanAndConnect)),
          if (connected) ...[
            Expanded(child: evaActionBtn(
              '断开', Icons.link_off, evaRed,
              (_diagRunning || _enduranceRunning) ? null : _disconnect)),
            const SizedBox(width: 8),
            Expanded(child: evaActionBtn(
              _diagRunning ? '診断中...' : '通讯診断',
              Icons.speed, evaCyan,
              (_diagRunning || _enduranceRunning) ? null : _runDiag)),
          ],
        ]),
        // ★ 耐久测试按钮
        if (connected) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: evaActionBtn(
              _enduranceRunning ? '耐久測試中... (5分)' : '耐久測試 (5分)',
              Icons.timer, evaAmber,
              (_diagRunning || _enduranceRunning) ? null : _runEndurance)),
            if (_enduranceRunning) ...[
              const SizedBox(width: 8),
              Expanded(child: evaActionBtn(
                '中止', Icons.stop, evaRed, _stopEndurance)),
            ],
          ]),
        ],
        if (connected && BtManager.instance.vin.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('VIN: ${BtManager.instance.vin}', style: TextStyle(fontFamily: 'monospace',
            fontSize: 8, fontWeight: FontWeight.w700, color: evaAmber.withOpacity(0.3))),
        ],
        // ★ 诊断日志面板
        if (_diagLog.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('DIAG LOG', style: TextStyle(fontFamily: 'monospace',
              fontSize: 7, fontWeight: FontWeight.w900, color: evaCyan.withOpacity(0.4))),
            const Spacer(),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _diagLog.join('\n')));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: const Text('診断ログをコピーしました',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  backgroundColor: evaCyan.withOpacity(0.9),
                  duration: const Duration(seconds: 2)));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: evaCyan.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: evaCyan.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.copy, size: 10, color: evaCyan),
                  const SizedBox(width: 4),
                  Text('COPY', style: TextStyle(fontFamily: 'monospace',
                    fontSize: 7, fontWeight: FontWeight.w900, color: evaCyan)),
                ]))),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _diagLog.clear()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: evaRed.withOpacity(0.3))),
                child: Text('CLR', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 7, fontWeight: FontWeight.w900, color: evaRed.withOpacity(0.6))))),
          ]),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: evaCyan.withOpacity(0.2))),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(_diagLog.join('\n'),
                style: const TextStyle(fontFamily: 'monospace',
                  fontSize: 7.5, fontWeight: FontWeight.w600,
                  color: Color(0xFFAAFFAA), height: 1.4)))),
        ],
        // ══════════════════════════════════════════════════════════
        // ★ EVA 同步率 — log 文本框外部下方, 固定位置
        // ══════════════════════════════════════════════════════════
        if (_syncRate > 0) ...[
          const SizedBox(height: 10),
          _buildEvaSyncRateWidget(),
        ],
      ]));
  }

  // ══════════════════════════════════════════════════════════════
  // ★ EVA 同步率显示组件 — 新世纪福音战士 插入栓同步风格
  // ══════════════════════════════════════════════════════════════

  Widget _buildEvaSyncRateWidget() {
    // 颜色和状态
    Color barColor;
    Color glowColor;
    String statusText;
    if (_syncRate >= 150) {
      barColor = evaRed;
      glowColor = evaRed;
      statusText = '[ 暴走 ]';
    } else if (_syncRate >= 100) {
      barColor = evaGreen;
      glowColor = evaGreen;
      statusText = '[ 完全同步 ]';
    } else if (_syncRate >= 80) {
      barColor = evaCyan;
      glowColor = evaCyan;
      statusText = '[ 高同步率 ]';
    } else if (_syncRate >= 50) {
      barColor = evaAmber;
      glowColor = evaAmber;
      statusText = '[ 同步稳定 ]';
    } else {
      barColor = evaRed.withOpacity(0.6);
      glowColor = evaRed;
      statusText = '[ 同步不足 ]';
    }

    final clampedRate = _syncRate.clamp(0, 200).toDouble();
    final barFraction = (clampedRate / 200).clamp(0.0, 1.0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: barColor.withOpacity(0.4)),
        boxShadow: _syncRate >= 150 ? [
          BoxShadow(color: glowColor.withOpacity(0.15), blurRadius: 12),
        ] : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 标题行
        Row(children: [
          Text('SYNC RATE', style: TextStyle(fontFamily: 'monospace',
            fontSize: 7, fontWeight: FontWeight.w900,
            color: barColor.withOpacity(0.6))),
          const Spacer(),
          Text(statusText, style: TextStyle(fontFamily: 'monospace',
            fontSize: 8, fontWeight: FontWeight.w900, color: barColor,
            shadows: _syncRate >= 150 ? [
              Shadow(color: glowColor.withOpacity(0.8), blurRadius: 6),
            ] : null)),
        ]),
        const SizedBox(height: 6),
        // 同步率数值
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_syncRate.toStringAsFixed(1),
            style: TextStyle(fontFamily: 'monospace',
              fontSize: 28, fontWeight: FontWeight.w900,
              color: barColor, height: 1,
              shadows: _syncRate >= 150 ? [
                Shadow(color: glowColor.withOpacity(0.6), blurRadius: 8),
              ] : null)),
          Padding(padding: const EdgeInsets.only(bottom: 3, left: 2),
            child: Text('%', style: TextStyle(fontFamily: 'monospace',
              fontSize: 12, fontWeight: FontWeight.w900,
              color: barColor.withOpacity(0.6)))),
        ]),
        const SizedBox(height: 6),
        // 进度条
        Container(
          height: 6,
          width: double.infinity,
          decoration: BoxDecoration(
            color: barColor.withOpacity(0.08),
            borderRadius: BorderRadius.circular(3),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: barFraction,
            child: Container(
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(color: glowColor.withOpacity(0.4), blurRadius: 4),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // 刻度标记
        Row(children: [
          Text('0%', style: TextStyle(fontFamily: 'monospace',
            fontSize: 6, color: DS.textDim)),
          const Spacer(),
          Container(width: 1, height: 4, color: evaAmber.withOpacity(0.3)),
          const SizedBox(width: 2),
          Text('50%', style: TextStyle(fontFamily: 'monospace',
            fontSize: 6, color: evaAmber.withOpacity(0.4))),
          const SizedBox(width: 2),
          Container(width: 1, height: 4, color: evaAmber.withOpacity(0.3)),
          const Spacer(),
          Container(width: 1, height: 6, color: evaGreen.withOpacity(0.5)),
          const SizedBox(width: 2),
          Text('100%', style: TextStyle(fontFamily: 'monospace',
            fontSize: 6, color: evaGreen.withOpacity(0.5))),
          const SizedBox(width: 2),
          Container(width: 1, height: 6, color: evaGreen.withOpacity(0.5)),
          const Spacer(),
          Text('200%', style: TextStyle(fontFamily: 'monospace',
            fontSize: 6, color: DS.textDim)),
        ]),
      ]),
    );
  }

  Widget _linkModeBtn(String label, BtLinkMode mode, bool selected) {
    final color = selected ? evaCyan : DS.textDim;
    final connected = BtManager.instance.isConnected;
    return Expanded(child: GestureDetector(
      onTap: connected ? null : () => _setLinkMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? evaCyan.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? evaCyan.withOpacity(0.5) : DS.border)),
        child: Center(child: Text(label, style: TextStyle(fontFamily: 'monospace',
          fontSize: 9, fontWeight: FontWeight.w800, color: color))))));
  }
}