// ════════════════════════════════════════════════════════════════
// did_scanner_card.dart — 适配器能力 + UDS DID 扫描
// ════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/bt_manager.dart';
import '../theme/eva_theme.dart';

/// 扫描结果
class DidScanResult {
  final int did;
  final int payloadBytes;
  final String rawHex;
  const DidScanResult(this.did, this.payloadBytes, this.rawHex);
}

/// 适配器命令探测结果
class CmdProbeResult {
  final String cmd;
  final String desc;
  final bool supported;
  final String response;
  const CmdProbeResult(this.cmd, this.desc, this.supported, this.response);
}

class DidScannerCard extends StatefulWidget {
  const DidScannerCard({super.key});
  @override State<DidScannerCard> createState() => _DidScannerCardState();
}

class _DidScannerCardState extends State<DidScannerCard> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    BtManager.instance.addListener(_onBtChanged);
  }

  @override
  void dispose() {
    BtManager.instance.removeListener(_onBtChanged);
    _scanning = false;
    super.dispose();
  }

  void _onBtChanged() {
    if (mounted) setState(() {});
  }
  int _scanned = 0;
  int _total = 0;
  int _found = 0;
  String _status = '就绪';
  final List<DidScanResult> _results = [];
  final List<CmdProbeResult> _probeResults = [];
  final List<String> _log = [];
  bool _probeDone = false;

  // UDS DID 扫描范围 (覆盖 Chery ECU 全部可能区间)
  static const _scanRanges = [
    (0x1000, 0x1030, '诊断/会话'),
    (0x2000, 0x2040, '发动机基础'),
    (0x2040, 0x2060, '环境/BARO'),
    (0x2060, 0x2080, '空气/进气'),
    (0x2080, 0x20A0, '燃油系统'),
    (0x5000, 0x5040, '变速箱 7DCT'),
    (0x6000, 0x6060, '扭矩/点火'),
    (0x6100, 0x6160, '空燃比 Lambda'),
    (0x6180, 0x61A0, '凸轮轴'),
    (0x6200, 0x6260, '空气质量'),
    (0xD000, 0xD080, '扩展发动机'),
    (0xF100, 0xF1A0, 'VIN/车辆信息'),
  ];

  // 适配器能力探测命令 (不含 ATZ/ATSP/ATM 等改变连接状态的命令)
  static const _probeCommands = [
    ('ATI', '设备识别'),
    ('ATDP', '当前协议'),
    ('ATDPN', '协议号'),
    ('ATRV', '电瓶电压'),
    ('STI', 'STN 芯片信息'),
    ('STDIX', 'STN 扩展信息'),
    ('STPX', 'STPX 命令测试'),
    ('STBC', 'STBC 批量命令'),
    ('STCSEGR', '硬件 ISO-TP 拼包'),
    ('STCSEGT', '硬件 ISO-TP 发送'),
    ('ATAT0', '自适应定时-慢'),
    ('ATAT2', '自适应定时-快'),
    ('ATS0', '关闭空格'),
    ('ATS1', '开启空格'),
    ('ATH0', '关闭 CAN 头'),
    ('ATH1', '开启 CAN 头'),
    ('ATAL', '允许长消息'),
    ('ATCAF0', '关闭 CAN 自动格式化'),
    ('ATCAF1', '开启 CAN 自动格式化'),
    ('ATCFC0', '关闭流控'),
    ('ATCFC1', '开启流控'),
  ];

  int get _totalDids =>
      _scanRanges.fold(0, (s, r) => s + r.$2 - r.$1 + 1);

  // ═══ 适配器能力扫描 ═══
  Future<void> _startProbe() async {
    final bt = BtManager.instance;
    if (!bt.isConnected) {
      setState(() => _status = '请先连接蓝牙');
      return;
    }

    setState(() {
      _scanning = true;
      _status = '探测适配器命令...';
      _probeResults.clear();
      _probeDone = false;
      _log.clear();
    });

    _log.add('=== 适配器能力探测 ===');
    _log.add('设备: ${bt.deviceName}');
    _log.add('');

    // ★ 不发送 ATZ: 会摧毁当前 OBD-II 初始化状态
    for (final (cmd, desc) in _probeCommands) {
      if (!_scanning) break;

      _log.add('测试: $cmd ($desc)');
      final resp = await bt.raw(cmd, timeout: 1.0, silent: true);

      final supported = resp.isNotEmpty &&
          !resp.toUpperCase().contains('?') &&
          !resp.toUpperCase().contains('ERROR');

      _probeResults.add(CmdProbeResult(cmd, desc, supported, resp));

      final icon = supported ? '✅' : '❌';
      final summary = resp.isEmpty ? '(无响应)' :
          resp.length > 40 ? '${resp.substring(0, 40)}...' : resp;
      _log.add('  $icon $summary');

      setState(() {});
      await Future.delayed(const Duration(milliseconds: 20));
    }

    // 总结
    final stnCmds = _probeResults.where((r) => r.cmd.startsWith('ST')).toList();
    final stnOk = stnCmds.where((r) => r.supported).length;
    _log.add('');
    _log.add('=== 探测完成 ===');
    _log.add('STN 命令: $stnOk/${stnCmds.length} 支持');
    if (stnOk > 0) {
      _log.add('✅ 适配器有 STN 芯片，支持高速命令');
    } else {
      _log.add('⚠ 适配器为 ELM327 兼容 (无 STN 芯片)');
      _log.add('  STPX/STBC/STCSEGR 不可用');
    }

    setState(() {
      _scanning = false;
      _probeDone = true;
      _status = '探测完成';
    });
  }

  // ═══ UDS DID 扫描 ═══
  Future<void> _startScan() async {
    final bt = BtManager.instance;
    if (!bt.isConnected) {
      setState(() => _status = '请先连接蓝牙');
      return;
    }

    setState(() {
      _scanning = true;
      _scanned = 0;
      _total = _totalDids;
      _found = 0;
      _status = '扫描中...';
      _results.clear();
      _log.clear();
    });

    _log.add('=== UDS DID 扫描开始 ===');
    _log.add('设备: ${bt.deviceName}  协议: ${bt.protocol}');

    // 设置 UDS 诊断 header (7E0/7E8) 并缓存
    await bt.setHeader('7E0', '7E8');
    _log.add('设置 UDS header: 7E0/7E8');

    // 先测试 Service 0x22 是否被 ECU 支持
    _log.add('测试 UDS Service 0x22...');
    final testResp = await bt.raw('221000', timeout: 1.5, silent: true);

    if (testResp.isEmpty || testResp.toUpperCase().contains('NO DATA')) {
      _log.add('❌ Service 0x22 无响应 — ECU 可能不支持 UDS');
      _log.add('建议继续使用 OBD-II Mode 01 模式');
      setState(() {
        _scanning = false;
        _status = 'ECU 不支持 UDS';
      });
      return;
    }
    _log.add('✅ Service 0x22 有响应 — 开始扫描...');

    // 遍历所有范围
    for (final (start, end, desc) in _scanRanges) {
      if (!_scanning) break;
      _log.add('扫描 $desc (0x${start.toRadixString(16).padLeft(4, '0')}-0x${end.toRadixString(16).padLeft(4, '0')})...');

      for (var did = start; did <= end && _scanning; did++) {
        final didStr = '22${did.toRadixString(16).padLeft(4, '0').toUpperCase()}';
        final resp = await bt.raw(didStr, timeout: 0.15, silent: true);

        if (resp.isNotEmpty && !resp.toUpperCase().contains('NO DATA')) {
          final bytes = BtManager.parseHexResponse(resp);
          if (bytes != null && bytes.length >= 4 && bytes[0] == 0x62) {
            final echoDid = (bytes[1] << 8) | bytes[2];
            if (echoDid == did) {
              final payloadLen = bytes.length - 3;
              final rawHex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
              _results.add(DidScanResult(did, payloadLen, rawHex));
              _found++;
              _log.add('  ✅ 0x${did.toRadixString(16).padLeft(4, '0')} (${payloadLen}B)');
            }
          }
        }

        _scanned++;
        if (_scanned % 50 == 0 && mounted) {
          setState(() {
            _status = '扫描中... $_scanned/$_total (发现 $_found)';
          });
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }
    }

    // ★ 恢复 OBD-II header (7DF/7E8), 清除 UDS header 缓存
    await bt.setHeader('7DF', '7E8');
    _log.add('恢复 OBD-II header: 7DF/7E8');

    _log.add('=== 扫描完成: 发现 $_found 个 DID ===');
    if (_found == 0) {
      _log.add('Chery ECU 不支持 UDS Service 0x22');
      _log.add('请继续使用 OBD-II Mode 01');
    }

    setState(() {
      _scanning = false;
      _status = _found > 0 ? '发现 $_found 个 UDS DID' : 'ECU 不支持 UDS';
    });
  }

  void _stop() {
    setState(() {
      _scanning = false;
      _status = '已停止';
    });
  }

  void _copyResults() {
    final sb = StringBuffer();
    sb.writeln('# === 适配器能力探测 ===');
    for (final r in _probeResults) {
      sb.writeln('# ${r.supported ? '✅' : '❌'} ${r.cmd}: ${r.desc}');
    }
    if (_results.isNotEmpty) {
      sb.writeln();
      sb.writeln('# === Arrizo 8 UDS DID ===');
      for (final r in _results) {
        final didHex = r.did.toRadixString(16).padLeft(4, '0').toUpperCase();
        final parse = r.payloadBytes <= 1 ? 'u8' : r.payloadBytes <= 2 ? 'u16' : 'u32';
        sb.writeln('arrizo_$didHex = $didHex, 7E0, 7E8, $parse, 0, 1.0, 0, ?, misc, 1, 100, , ARZ_$didHex, DID 0x$didHex (${r.payloadBytes}B)');
      }
    }
    Clipboard.setData(ClipboardData(text: sb.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bt = BtManager.instance;
    final connected = bt.isConnected;

    return EvaCard(
      title: 'ADAPTER SCAN',
      subtitle: '适配器能力 + DID 发现',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 状态 + 按钮
        Row(children: [
          Expanded(child: Text(_status, style: TextStyle(
            fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700,
            color: _scanning ? evaAmber : (_found > 0 || _probeDone ? evaGreen : DS.textSec),
          ))),
          if (_scanning)
            TextButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop, size: 14, color: evaRed),
              label: Text('停止', style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: evaRed)),
            )
          else Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton.icon(
              onPressed: connected ? _startProbe : null,
              icon: Icon(Icons.memory, size: 14, color: connected ? evaAmber : DS.textDim),
              label: Text('探测适配器', style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                color: connected ? evaAmber : DS.textDim)),
            ),
            TextButton.icon(
              onPressed: connected ? _startScan : null,
              icon: Icon(Icons.search, size: 14, color: connected ? evaCyan : DS.textDim),
              label: Text('扫描 DID', style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                color: connected ? evaCyan : DS.textDim)),
            ),
          ]),
          if (!_scanning && (_probeResults.isNotEmpty || _results.isNotEmpty))
            TextButton.icon(
              onPressed: _copyResults,
              icon: const Icon(Icons.copy, size: 14, color: evaGreen),
              label: Text('复制', style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: evaGreen)),
            ),
        ]),

        // 适配器探测结果
        if (_probeResults.isNotEmpty) ...[
          const SizedBox(height: 4),
          _sectionHeader('适配器命令支持'),
          Container(
            decoration: BoxDecoration(color: DS.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: DS.border)),
            padding: const EdgeInsets.all(6),
            child: Column(children: _probeResults.map((r) =>
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  SizedBox(width: 16, child: Icon(
                    r.supported ? Icons.check_circle : Icons.cancel,
                    size: 12, color: r.supported ? evaGreen : evaRed.withOpacity(0.5),
                  )),
                  SizedBox(width: 80, child: Text(r.cmd, style: TextStyle(
                    fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700,
                    color: r.supported ? DS.textPri : DS.textDim,
                  ))),
                  Expanded(child: Text(r.desc, style: TextStyle(
                    fontFamily: 'monospace', fontSize: 8, color: DS.textDim,
                  ))),
                ]),
              ),
            ).toList()),
          ),
        ],

        // DID 进度
        if (_scanning && _total > 0) ...[
          const SizedBox(height: 4),
          ClipRRect(borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: _scanned / _total,
              backgroundColor: DS.border, valueColor: const AlwaysStoppedAnimation<Color>(evaCyan),
            ),
          ),
          Text('$_scanned / $_total  (发现 $_found)', style: TextStyle(fontFamily: 'monospace', fontSize: 7, color: DS.textDim)),
        ],

        // DID 结果
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 4),
          _sectionHeader('发现 ${_results.length} 个 UDS DID'),
          Container(
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(color: DS.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: DS.border)),
            child: ListView.builder(shrinkWrap: true, itemCount: _results.length,
              itemBuilder: (ctx, i) {
                final r = _results[i];
                return Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Row(children: [
                    SizedBox(width: 70, child: Text(
                      '0x${r.did.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700, color: evaCyan),
                    )),
                    Text('${r.payloadBytes}B', style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: DS.textSec)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.rawHex, style: TextStyle(fontFamily: 'monospace', fontSize: 8, color: DS.textDim), overflow: TextOverflow.ellipsis)),
                  ]),
                );
              },
            ),
          ),
        ],

        // 日志
        if (_log.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(width: double.infinity, padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(4)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: _log.reversed.take(6).toList().reversed.map((l) =>
                Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                  color: l.contains('✅') ? evaGreen
                      : l.contains('❌') ? evaRed
                      : l.contains('===') ? evaAmber
                      : DS.textDim)),
              ).toList(),
            ),
          ),
        ],

        if (!connected)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('⚠ 请先连接蓝牙适配器', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, color: evaRed.withOpacity(0.6))),
          ),
      ]),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(padding: const EdgeInsets.only(bottom: 2),
      child: Text(text, style: TextStyle(fontFamily: 'monospace', fontSize: 8,
        fontWeight: FontWeight.w700, color: DS.textSec)),
    );
  }
}
