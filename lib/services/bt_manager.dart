// ════════════════════════════════════════════════════════════════
// bt_manager.dart — 蓝牙通讯管理器 (重構版)
// ════════════════════════════════════════════════════════════════
// UDS (ISO 14229)
// OBDLink MX+ (SPP) / CX (BLE) 适配器
// Android SPP (MX+) + BLE (CX), iOS BLE only (CX)
// ════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show VoidCallback;
import 'package:permission_handler/permission_handler.dart';
import '../models/obd_pids.dart';
import '../models/vehicle_profile.dart';
import 'obd_transport.dart';
import 'spp_transport.dart';
import 'ble_transport.dart';

typedef BtLogCallback = void Function(String tag, String msg);

/// 蓝牙链路模式 (物理层)
enum BtLinkMode {
  /// Classic Bluetooth SPP — Android only (OBDLink MX+)
  spp,
  /// Bluetooth Low Energy 5.1 — Android + iOS (OBDLink CX)
  ble,
}

// ═══ 异步互斥锁 ═══

class _AsyncMutex {
  Completer<void>? _lock;
  Future<T> run<T>(Future<T> Function() fn) async {
    while (_lock != null) {
      try { await _lock!.future; } catch (_) {}
    }
    _lock = Completer<void>();
    try {
      return await fn();
    } finally {
      final c = _lock;
      _lock = null;
      c?.complete();
    }
  }
}

// ════════════════════════════════════════════════════════════════
// BtManager (单例)
// ════════════════════════════════════════════════════════════════

class BtManager {
  static final BtManager instance = BtManager._();
  BtManager._();

  // ── 连接状态 ──
  OBDTransport? _transport;
  StreamSubscription? _connStateSub;
  bool isConnected = false;
  String deviceName = '';
  String deviceAddress = '';

  // ── 自动重连 ──
  OBDDevice? _lastDevice;            // 最近成功连接的设备
  bool _userDisconnecting = false;   // 用户主动断开标志
  bool _reconnecting = false;        // 正在重连中
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  static const _reconnectDelaysMs = [1000, 2000, 4000]; // 指数退避

  /// 重连状态流 — LiveDataService 监听此流以恢复轮询
  /// 值: true = 重连成功, false = 重连放弃
  final _reconnectCtrl = StreamController<bool>.broadcast();
  Stream<bool> get onReconnect => _reconnectCtrl.stream;

  /// 是否正在自动重连中
  bool get isReconnecting => _reconnecting;

  // ── 设备/协议信息 ──
  String elmId = '';
  String protocol = '';
  String vin = '';

  // ── 通讯模式 ──
  CommMode commMode = CommMode.uds;

  /// 蓝牙链路: SPP (MX+) 或 BLE (CX)
  BtLinkMode linkMode = BtLinkMode.spp;

  // ═══ ★ VehicleProfile 参数访问器 ═══
  // 当 ProfileManager 有 active profile 时从 INI 读取, 否则使用内置默认值

  VehicleProfile? get _profile => ProfileManager.instance.active;

  /// ECU 地址表 (从 profile 或内置默认)
  List<List<String>> get _ecuListFromProfile {
    final p = _profile;
    if (p != null && p.ecuList.isNotEmpty) {
      return p.ecuList.map((e) => [e.tx, e.rx, e.description]).toList();
    }
    return _builtinEcuList;
  }

  /// 当前活跃 ECU 发送地址 (外部可读)
  String get activeEcuTx => _ecuTx;
  /// 当前活跃 ECU 接收地址 (外部可读)
  String get activeEcuRx => _ecuRx;

  /// 动态 DID 目标地址 (从 profile 或内置默认 0xF300)
  int get dynamicDidTarget => _profile?.dynamicDidTarget ?? 0xF300;

  /// 慢变化 PID 集合 (从 profile 或内置默认)
  Set<String> get slowChangePidIds => _profile?.slowChangePids ?? _builtinSlowChangePids;

  /// 慢变化轮询间隔
  int get slowChangeInterval => _profile?.slowChangeInterval ?? 3;

  // 内置默认慢变化 PID (向后兼容)
  static const _builtinSlowChangePids = <String>{
    'uds_iat_b1', 'uds_ambient', 'uds_airfilter',
    'uds_fuel_lp', 'uds_fuel_hp', 'uds_hpfp',
    'uds_lambda_b1', 'uds_lambda_sp',
    'uds_exh_cam_b1', 'uds_int_cam_b1',
    'uds_wastegate', 'uds_airmass',
    'uds_inj_b1', 'uds_inj_b2',
  };

  // ── 总线锁 ──
  final _busLock = _AsyncMutex();

  // ── 收发缓冲 ──
  final StringBuffer _rxBuf = StringBuffer();
  bool _rxGotPrompt = false;  // ★ 直接追踪 '>' 字符, 避免 O(n²) toString().contains()
  Completer<String>? _rxCompleter;
  StreamSubscription? _inputSub;

  // ── UDS 会话 (仅 UDS 模式) ──
  final Set<String> _sessions = {};
  String _lastTx = '';  // ★ header 缓存: 避免重复发 ATSH/ATCRA/ATFC
  bool hbRunning = false;
  Timer? _hbTimer;

  // ── STN 扩展能力 (OBDLink MX+ / CX) ──
  bool _stnAvailable = false;   // ★ STN 芯片检测到 (ST 命令集可用)
  bool _stpxAvailable = false;  // ★ STPX 命令可用 (多帧 ISO-TP 发送)
  bool _stbcEnabled = false;    // ★ STBC 批量命令已启用
  bool _stcsegrEnabled = false; // ★ STCSEGR 1 硬件 RX 拼包 (芯片自动重组多帧)
  String? _periodicHbHandle;    // ★ STPPMA 周期心跳句柄 (芯片端自动发送)
  bool get stpxAvailable => _stpxAvailable;
  bool get stnAvailable => _stnAvailable;

  // ── 热路径缓存 (避免每周期重复分配) ──
  static final _hexCharRegExp = RegExp(r'^[0-9A-Fa-f]+$');  // ★ 预编译 RegExp
  Uint8List? _dynDidCmdBytes;   // ★ 缓存 "22F300\r" 的字节 (readDynamicDid 热路径)
  static const _hexLut = <int>[   // ★ hex char → int 查找表 (避免 int.parse)
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x00-0x0F
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x10-0x1F
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x20-0x2F
     0, 1, 2, 3, 4, 5, 6, 7, 8, 9,-1,-1,-1,-1,-1,-1, // 0x30-0x3F ('0'-'9')
    -1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x40-0x4F ('A'-'F')
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x50-0x5F
    -1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1, // 0x60-0x6F ('a'-'f')
  ];

  // ── RAW 指令追踪 (HUD 调试用) ──
  // ★ 轻量环形缓冲: 记录 TX/RX 原始指令 + 时间戳
  //   开启后仅在 raw() 和 readDynamicDid 热路径中追加字符串
  //   退出 HUD 时导出剪贴板, 用于分析掉帧原因
  bool rawTraceEnabled = false;
  final List<String> _rawTrace = [];
  DateTime? _rawTraceT0;
  static const _rawTraceMax = 8000;  // 约 5 分钟 @ 20Hz

  /// 开始追踪
  void rawTraceStart() {
    _rawTrace.clear();
    _rawTraceT0 = DateTime.now();
    rawTraceEnabled = true;
    _rawTrace.add('=== RAW TRACE START ${_rawTraceT0!.toIso8601String()} ===');
    _rawTrace.add('link: ${linkMode == BtLinkMode.ble ? "BLE" : "SPP"}  '
        'stn: $_stnAvailable  stpx: $_stpxAvailable  '
        'stcsegr: $_stcsegrEnabled  stbc: $_stbcEnabled');
  }

  /// 停止追踪, 返回全部日志文本
  String rawTraceStop() {
    rawTraceEnabled = false;
    final elapsed = _rawTraceT0 != null
        ? DateTime.now().difference(_rawTraceT0!).inMilliseconds
        : 0;
    _rawTrace.add('=== RAW TRACE END  ${elapsed}ms  ${_rawTrace.length} entries ===');
    return _rawTrace.join('\n');
  }

  /// 追踪写入 (热路径, 仅在 enabled 时执行)
  void _tr(String entry) {
    if (!rawTraceEnabled) return;
    final ms = _rawTraceT0 != null
        ? DateTime.now().difference(_rawTraceT0!).inMilliseconds
        : 0;
    _rawTrace.add('${ms.toString().padLeft(7)}  $entry');
    if (_rawTrace.length > _rawTraceMax) {
      _rawTrace.removeRange(0, 500);  // 淘汰最早 500 条
    }
  }

  /// 外部追踪写入 (供 LiveDataService 等调用)
  void tr(String entry) => _tr(entry);

  // ── 监听器 ──
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() { for (final cb in _listeners) {
    cb();
  } }

  // ── 日志 ──
  BtLogCallback? onLog;
  void _log(String tag, String msg) => onLog?.call(tag, msg);

  /// ★ HUD 轮询诊断结果 (进入 HUD 后自动填充, 退出后可查看)
  String? hudDiagResult;

  // ── EVA 同步率回调 (UI 在 log 文本框外部下方显示) ──
  // syncRate: 百分比 (采样极限 10Hz = 100%), label: 显示文案
  void Function(double syncRate, String label)? onSyncRate;

  /// 计算并推送 EVA 同步率
  void _pushSyncRate(double bestHz) {
    final rate = (bestHz / 10.0) * 100;
    String label;
    if (rate >= 150) {
      label = '暴走';
    } else if (rate >= 100) {
      label = '完全同步';
    } else if (rate >= 80) {
      label = '高同步率';
    } else if (rate >= 50) {
      label = '同步稳定';
    } else {
      label = '同步不足';
    }
    onSyncRate?.call(rate, label);
  }

  // ═══════════════════════════════════════════════════════════════
  // 权限 / 蓝牙状态
  // ═══════════════════════════════════════════════════════════════

  static Future<bool> ensurePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.locationWhenInUse,
      ].request();
      return statuses.values.every((s) => s.isGranted || s.isLimited);
    }
    if (Platform.isIOS) {
      // iOS BLE 权限在 Info.plist 中声明, 系统自动弹窗
      return true;
    }
    return false;
  }

  static Future<bool> isBluetoothEnabled() async {
    final mode = BtManager.instance.linkMode;
    if (Platform.isAndroid && mode == BtLinkMode.spp) {
      return await SppTransport.isBluetoothEnabled();
    }
    // BLE — flutter_blue_plus 跨平台
    return await BleTransport.isBluetoothEnabled();
  }

  static Future<bool> requestEnable() async {
    final mode = BtManager.instance.linkMode;
    if (Platform.isAndroid && mode == BtLinkMode.spp) {
      return await SppTransport.requestEnable();
    }
    // BLE: iOS 无法编程式开启, Android BLE 也不保证
    return await BleTransport.requestEnable();
  }

  /// 获取设备列表 — SPP: 配对设备; BLE: 扫描 OBDLink CX
  static Future<List<OBDDevice>> getDevices() async {
    final mode = BtManager.instance.linkMode;
    if (Platform.isAndroid && mode == BtLinkMode.spp) {
      return await SppTransport.getDevices();
    }
    // BLE 扫描 (过滤 FFF0 服务)
    return await BleTransport.scanDevices(timeout: const Duration(seconds: 5));
  }

  // ═══════════════════════════════════════════════════════════════
  // 连接 / 断开
  // ═══════════════════════════════════════════════════════════════

  Future<bool> connect(OBDDevice device) async {
    if (isConnected) await disconnect();
    try {
      _log('SYS', '连接 ${device.name} (${linkMode == BtLinkMode.ble ? "BLE" : "SPP"})...');

      // ★ 根据 linkMode 选择传输层
      if (linkMode == BtLinkMode.ble) {
        _transport = BleTransport();
      } else {
        _transport = SppTransport();
      }
      await _transport!.connect(device);

      isConnected = true;
      deviceName = device.name;
      deviceAddress = device.address;
      _lastDevice = device;           // ★ 保存设备引用, 断线重连用
      _reconnectAttempts = 0;
      _reconnecting = false;

      // 数据接收 + 断开检测
      _subscribeTransport(); // ★ 数据接收 + 意外断连检测

      _log('SYS', '✅ 蓝牙已连接 (${linkMode == BtLinkMode.ble ? "低功耗模式" : "经典模式"})');
      if (linkMode == BtLinkMode.ble && _transport is BleTransport) {
        final ble = _transport as BleTransport;
        _log('SYS', '  数据包大小: ${ble.negotiatedMtu}  '
            '传输模式: ${ble.negotiatedMtu > 23 ? "高速" : "标准"}');
      }
      await Future.delayed(Duration(milliseconds: linkMode == BtLinkMode.ble ? 800 : 500));

      // ── AT 初始化 (按通讯模式分支) ──
      if (commMode == CommMode.obd2) {
        await _initObd2();
      } else {
        await _initUds();
      }

      _notify();
      return true;
    } catch (e) {
      _log('ERR', '连接失败: $e');
      isConnected = false;
      _notify();
      return false;
    }
  }

  /// ★ 订阅传输层: 数据接收 + 意外断连检测
  /// connect() 和 _attemptReconnect() 共用
  void _subscribeTransport() {
    _inputSub = _transport!.dataStream.listen(
      (Uint8List data) {
        _rxBuf.write(ascii.decode(data, allowInvalid: true));
        // ★ 直接在原始字节中检查 '>' (0x3E), 避免 toString() + contains()
        if (!_rxGotPrompt) {
          for (var i = 0; i < data.length; i++) {
            if (data[i] == 0x3E) { _rxGotPrompt = true; break; }
          }
        }
        if (_rxGotPrompt) {
          _rxCompleter?.complete(_rxBuf.toString());
          _rxBuf.clear();
          _rxGotPrompt = false;
        }
      },
      onError: (e) => _log('ERR', '接收错误: $e'),
    );

    // 断开检测 — 意外断连时自动重连
    _connStateSub = _transport!.connectionState.listen((connected) {
      if (!connected && !_userDisconnecting) {
        isConnected = false;
        _sessions.clear();
        _lastTx = '';
        stopHeartbeat();
        _log('SYS', '⚠ 蓝牙意外断开');
        _notify();
        _attemptReconnect();
      }
    });
  }

  /// ★ 自动重连 — 指数退避, 最多 3 次
  Future<void> _attemptReconnect() async {
    if (_reconnecting || _lastDevice == null) return;
    _reconnecting = true;

    final device = _lastDevice!;
    _log('SYS', '🔄 开始自动重连 ${device.name}...');

    for (var i = 0; i < _maxReconnectAttempts; i++) {
      _reconnectAttempts = i + 1;
      final delayMs = _reconnectDelaysMs[i];
      _log('SYS', '  重连 #$_reconnectAttempts / $_maxReconnectAttempts'
          ' (等待 ${delayMs}ms)');
      _notify(); // ★ 通知 UI 显示重连状态

      await Future.delayed(Duration(milliseconds: delayMs));

      // ★ 如果用户在等待期间手动断开或退出 HUD, 取消重连
      if (_userDisconnecting || _lastDevice == null) {
        _log('SYS', '  重连取消 (用户操作)');
        _reconnecting = false;
        return;
      }

      try {
        // 重建传输层
        _inputSub?.cancel();
        _connStateSub?.cancel();
        try { await _transport?.disconnect(); } catch (_) {}

        if (linkMode == BtLinkMode.ble) {
          _transport = BleTransport();
        } else {
          _transport = SppTransport();
        }
        await _transport!.connect(device);

        isConnected = true;
        deviceName = device.name;
        deviceAddress = device.address;

        // 重新订阅数据接收 + 断开检测
        _subscribeTransport();

        // ★ 关键: 等待传输层稳定后恢复 AT 初始化
        await Future.delayed(Duration(
          milliseconds: linkMode == BtLinkMode.ble ? 800 : 500,
        ));
        if (commMode == CommMode.obd2) {
          await _initObd2();
        } else {
          await _initUds();
        }

        _log('SYS', '✅ 重连成功 (#$_reconnectAttempts)');
        _reconnecting = false;
        _reconnectAttempts = 0;
        _notify();
        _reconnectCtrl.add(true); // ★ 通知 LiveDataService 恢复轮询
        return;

      } catch (e) {
        _log('ERR', '  重连 #$_reconnectAttempts 失败: $e');
      }
    }

    // 全部尝试失败
    _log('SYS', '❌ 自动重连失败 (已尝试 $_maxReconnectAttempts 次)');
    _reconnecting = false;
    _reconnectAttempts = 0;
    _reconnectCtrl.add(false); // ★ 通知: 重连放弃
    _notify();
  }

  Future<void> disconnect() async {
    _userDisconnecting = true;       // ★ 标记: 主动断开, 不触发自动重连
    stopHeartbeat();

    // UDS: 退出扩展会话 → Default Session (10 01)
    // OBD-II: 无需会话管理, 跳过
    if (commMode == CommMode.uds && isConnected && _sessions.isNotEmpty) {
      try {
        // ★ 清除所有周期消息 (安全: 即使没有也不报错)
        if (_stnAvailable) {
          await raw('STPPMC', silent: true);
        }
        if (_stpxAvailable) {
          await raw('STPX H:$_ecuTx, D:1001', timeout: 2.0, silent: true);
        } else {
          await _setHeaderRaw(_ecuTx, _ecuRx);
          await raw('1001', silent: true);
        }
      } catch (_) {}
    }
    _sessions.clear();
    _lastTx = '';
    _stpxAvailable = false;
    _stnAvailable = false;
    _stbcEnabled = false;
    _stcsegrEnabled = false;
    _periodicHbHandle = null;
    _dynDidCmdBytes = null;    // ★ 清除热路径缓存
    _inputSub?.cancel();
    _connStateSub?.cancel();
    await _transport?.disconnect();
    _transport = null;
    isConnected = false;
    deviceName = '';
    deviceAddress = '';
    elmId = '';
    protocol = '';
    vin = '';
    _log('SYS', '已断开');
    _notify();
    _userDisconnecting = false;      // ★ 恢复标志
    _lastDevice = null;              // ★ 主动断开清除设备引用
  }


  // ═══════════════════════════════════════════════════════════════
  // AT 初始化 — UDS (对齐 Python 参考实现)
  // ═══════════════════════════════════════════════════════════════
  //
  //  Phase 1: ELM327 配置
  //  Phase 2: CAN 总线验证 (7DF 广播 01 00)
  //  Phase 3: ECU 探测 (遍历 ECU 列表, 10 01 probe)
  //  Phase 4: 流控设置 (仅一次)
  //  Phase 5: 扩展诊断会话 (10 03)
  //  Phase 6: 心跳启动 (3E 00 每 2 秒)
  //

  /// ECU 地址表 (内置默认) — 连接时逐个探测, 第一个响应的作为目标
  /// [tx, rx, description]
  /// ★ 运行时通过 _ecuListFromProfile 访问, 可被 INI 覆盖
  static const _builtinEcuList = [
    ['7E0', '7E8', 'ME (Engine ECU)'],
    ['7E2', '7EA', 'TCU (Transmission)'],
    ['7E4', '7EC', 'ESP'],
  ];

  /// 当前活跃 ECU 地址 (探测后设置)
  String _ecuTx = '7E0';
  String _ecuRx = '7E8';

  Future<void> _initUds() async {
    _log('SYS', '模式: UDS (ISO 14229)');

    // ── Phase 1: 硬复位 + 关回显 ──
    // ATZ 必须单独发 (设备重启); ATE0 必须在 STBC 之前 (否则回显干扰批量解析)
    await raw('AT Z', timeout: 3.0, silent: true);
    await Future.delayed(const Duration(milliseconds: 1500));
    await raw('ATE0', silent: true);
    await raw('ATL0', silent: true);

    // ── Phase 2: 探测 STN 芯片 (OBDLink MX+ / CX) ──
    final stiResp = (await raw('STI', timeout: 1.0, silent: true)).trim();
    _stnAvailable = stiResp.isNotEmpty &&
        !stiResp.toUpperCase().contains('?') &&
        !stiResp.toUpperCase().contains('ERROR');

    if (_stnAvailable) {
      _log('SYS', '✅ STN: $stiResp');

      // ── Phase 3a: STN 快速初始化 (STBC 批量命令) ──
      // 启用 STBC → 所有后续配置合并为 1 次蓝牙往返
      await raw('STBC 1', silent: true);
      _stbcEnabled = true;

      // ★★★ 核心: 批量发送所有配置 (1 次 BT 往返 ≈ 30ms vs 12 次 ≈ 500ms) ★★★
      // STBCOF 1: 抑制 OK 输出, 减少响应数据量
      // ATS0:     关闭空格, 减少 ~30% BLE 传输量
      // ATH1:     头部开启 (UDS 需要)
      // ATCAF1:   CAN 自动格式化
      // ATCFC1:   Flow Control 开启 (ISO-TP 多帧必须)
      // ATAT2:    激进自适应定时 (最快响应)
      // ATAL:     允许长消息 (Multi-DID > 7 字节)
      // STP:      ★ 协议号 (从 profile 或默认 33)
      // STPTO:    ★ 响应超时 (从 profile 或默认 50ms)
      // STCTOR:   ★ FC/CF 接收超时 (从 profile 或默认 50/100ms)
      // STPTRQ:   ★ 请求间延迟 (从 profile 或默认 0ms)
      final p = _profile;
      final stpProto = p?.stpProtocol ?? 33;
      final stpto = p?.stpto ?? 50;
      final stctorFc = p?.stctorFc ?? 50;
      final stctorCf = p?.stctorCf ?? 100;
      final stptrq = p?.stptrq ?? 0;
      await raw(
        'STBCOF 1'
        '|ATS0'
        '|ATH1'
        '|ATCAF1'
        '|ATCFC1'
        '|ATAT2'
        '|ATAL'
        '|STP $stpProto'
        '|STPTO $stpto'
        '|STCTOR $stctorFc, $stctorCf'
        '|STPTRQ $stptrq',
        silent: true,
      );

      _stpxAvailable = true; // STN 芯片 → STPX 必然可用

      // ── Phase 3c: 启用硬件 ISO-TP 拼包 (STCSEGR/STCSEGT) ──
      // ★ 不放入主批量命令: 若不支持会返回 '?' 终止整个批量执行
      // ★ 单独发送, 安全探测
      //
      // STCSEGR 1: 芯片自动重组多帧 RX → App 不再需要手动拼 FF+CF
      //   原: 3 帧 × BLE notify (30-45ms) + App 拼包
      //   新: 1 帧 × BLE notify (7.5-15ms) + 直接取数据
      //
      // STCSEGT 1: 芯片自动分割多帧 TX → 长消息自动发送
      //   与 STPX 的 TX 分段互为冗余, 但提供全局默认行为

      final stcsegrResp = await raw('STCSEGR 1', timeout: 1.0, silent: true);
      if (!stcsegrResp.contains('?') &&
          !stcsegrResp.toUpperCase().contains('ERROR')) {
        await raw('STCSEGT 1', silent: true);
        _stcsegrEnabled = true;
        _log('SYS', '✅ STCSEGR + STCSEGT (硬件 ISO-TP 拼包)');
      } else {
        _log('SYS', '⚠ STCSEGR 不可用, 使用软件拼包');
      }

      _log('SYS', '⚡ STN 批量初始化完成 (STBC + STP $stpProto + STPTO $stpto + STCTOR $stctorFc,$stctorCf + STPTRQ $stptrq + ATS0'
          '${_stcsegrEnabled ? " + STCSEGR" : ""})');
    } else {
      // ── Phase 3b: 非 STN 设备 — 逐条发送 (兼容 ELM327) ──
      _log('SYS', '⚠ 非 STN 芯片, 使用 ELM327 兼容模式');
      final elmProto = _profile?.elmProtocol ?? 6;
      final elmTo = _profile?.elmTimeout ?? '32';
      for (final cmd in [
        'ATS0',             // ★ 关闭空格 (ELM327 也支持)
        'ATH1',             // CAN 头部开启
        'ATCAF1',           // CAN 自动格式化
        'ATCFC1',           // Flow Control 开启
        'ATSP$elmProto',    // ISO 15765 协议 (从 profile 或默认 6)
        'ATAT2',            // 激进自适应定时
        'ATST$elmTo',       // 响应超时 (从 profile 或默认 32≈200ms)
        'ATAL',             // 允许长消息
      ]) {
        await raw(cmd, silent: true);
      }
    }

    elmId = (await raw('ATI', silent: true)).trim();
    protocol = (await raw(_stnAvailable ? 'STPRS' : 'ATDPN', silent: true)).trim();
    _log('SYS', '设备: $elmId');
    _log('SYS', '协议: $protocol');

    // ── Phase 4: CAN 总线验证 (广播) ──
    _log('SYS', '>>> CAN 总线测试');
    if (_stpxAvailable) {
      // STPX 直接验证 — 不需要先 ATSH (省 1 次往返)
      final canTest = await raw('STPX H:7DF, D:0100, T:5000', timeout: 6.0, silent: true);
      if (canTest.contains('NO DATA') || canTest.contains('ERROR') || canTest.isEmpty) {
        _log('ERR', 'CAN 总线无响应 — 检查 OBD 接口');
        return;
      }
    } else {
      await _setHeaderRaw('7DF', '');
      final canTest = await raw('0100', timeout: 5.0, silent: true);
      if (canTest.contains('NO DATA') || canTest.contains('ERROR') || canTest.isEmpty) {
        _log('ERR', 'CAN 总线无响应 — 检查 OBD 接口');
        return;
      }
    }
    _log('SYS', 'CAN OK');

    // ── Phase 5: ECU 探测 ──
    _log('SYS', '>>> ECU 探测');
    bool ecuFound = false;
    for (final ecu in _ecuListFromProfile) {
      final tx = ecu[0]; final rx = ecu[1]; final desc = ecu[2];
      String resp;
      if (_stpxAvailable) {
        // ★ STPX: header 内联, 省 ATSH+ATCRA 2 次往返
        resp = await raw('STPX H:$tx, D:1001, T:3000, R:1', timeout: 4.0, silent: true);
      } else {
        await _setHeaderRaw(tx, rx);
        await Future.delayed(const Duration(milliseconds: 100));
        resp = await raw('1001', timeout: 3.0, silent: true);
      }
      // 正响应 (50 01) 或 NRC 都说明 ECU 在线
      if (resp.isNotEmpty && !resp.contains('NO DATA') && !resp.contains('ERROR')) {
        _ecuTx = tx;
        _ecuRx = rx;
        ecuFound = true;
        _log('SYS', 'ECU: $desc ($tx/$rx)');
        break;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!ecuFound) {
      _log('ERR', '未找到 ECU');
      return;
    }

    // ── Phase 6: 流控 + CAN フィルタ ──
    if (_stnAvailable) {
      // ★ STN 原生: STCFCPA (1 命令 vs AT FC 3 命令)
      //   手册: 直接登録 FC アドレスペア → STCSEGR チップ内部FC処理に最適
      await raw('STCFCPA $_ecuTx, $_ecuRx', silent: true);
      // ★ STFPA パスフィルタ: ハードウェアレベルで $_ecuRx のみ通過
      //   手册 Section 8.10: CAN バス上の他 ECU ノイズをチップが遮断
      //   → UART/BT 負荷軽減, 高速ポーリング時の安定性向上
      //   11-bit CAN: 先頭 2バイト = CAN ID, 上位5bit は don't care
      await raw('STFPA 0$_ecuRx, 07FF', silent: true);
      _log('SYS', '✅ STCFCPA + STFPA (STN 原生 FC + パスフィルタ)');
    } else {
      // ELM327 互換: AT FC コマンド (3 往復)
      // ★ FC data/mode from profile (default: 300000 / mode 1)
      final fcData = _profile?.fcData ?? '300000';
      final fcMode = _profile?.fcMode ?? 1;
      await raw('ATFCSH$_ecuTx', silent: true);
      await raw('ATFCSD$fcData', silent: true);
      await raw('ATFCSM$fcMode', silent: true);
    }

    // ── Phase 7: 设置 header (用于非 STPX 通路) ──
    await _setHeaderRaw(_ecuTx, _ecuRx);

    // ── Phase 8: 扩展诊断会话 ──
    final sessPref = _profile?.sessionPreferred ?? '03';
    final sessFallback = _profile?.sessionFallback ?? '02';
    _log('SYS', '>>> Session 10 $sessPref');
    await Future.delayed(const Duration(milliseconds: 100));
    String sessResp;
    if (_stpxAvailable) {
      sessResp = await raw('STPX H:$_ecuTx, D:10$sessPref, T:3000, R:1', timeout: 4.0, silent: true);
    } else {
      sessResp = await raw('10$sessPref', timeout: 3.0, silent: true);
    }
    if (sessResp.isEmpty || sessResp.contains('NO DATA') || sessResp.contains('ERROR')) {
      // 退回尝试降级会话
      _log('SYS', '10 $sessPref 失败, 尝试 10 $sessFallback');
      if (_stpxAvailable) {
        sessResp = await raw('STPX H:$_ecuTx, D:10$sessFallback, T:3000, R:1', timeout: 4.0, silent: true);
      } else {
        sessResp = await raw('10$sessFallback', timeout: 3.0, silent: true);
      }
      if (sessResp.isEmpty || sessResp.contains('NO DATA') || sessResp.contains('ERROR')) {
        _log('ERR', '会话建立失败');
        return;
      }
    }
    _sessions.add(_ecuTx.toUpperCase());
    _log('SYS', '✅ 握手成功');

    // ── Phase 9: 读取 VIN → 启动心跳 ──
    // ★ 顺序很重要: 先读 VIN, 再启动心跳
    //   诊断会话刚建立, P2* 超时 = 5000ms, VIN 读取只需 ~50ms
    //   如果先 startHeartbeat() (void, 不 await), _setupPeriodicHeartbeat()
    //   与 _readVinUds() 并发竞争 busLock → STPPMA 响应混淆 → init 失败
    await _readVinUds();
    startHeartbeat();
  }

  // ═══════════════════════════════════════════════════════════════
  // OBD-II Mode 01 初始化 (vLinker MS / ELM327)
  // ═══════════════════════════════════════════════════════════════
  //
  //  基于 OBDProxy 实车验证的初始化序列:
  //    ATZ → ATE0 → ATH1 → ATSP6 → ATM0 → ATAT2 → ATDP → 0100暖机
  //
  //  ATSP6: ISO 15765-4 CAN 11/500 (直接指定, 秒锁协议)
  //  ATAT2: 激进自适应定时 (匹配 DKE 响应速度)
  //  0100:  暖机唤醒 CAN 控制器
  //

  Future<void> _initObd2() async {
    _log('SYS', '模式: OBD-II Mode 01 (ISO 15765-4)');

    // ── Phase 1: 硬复位 ──
    await raw('AT Z', timeout: 3.0, silent: true);
    await Future.delayed(const Duration(milliseconds: 1500));

    // ── Phase 2: ELM327 基础配置 ──
    await raw('ATE0', silent: true);   // 关闭回显
    await raw('ATL0', silent: true);   // 关闭换行
    await raw('ATH1', silent: true);   // 开启 CAN 头部
    await raw('ATSP6', silent: true);  // ★ ISO 15765-4 CAN 11/500
    await raw('ATAT2', silent: true);  // 激进自适应定时
    // ★ 不设 ATM0: 保留 ELM327 OBD-II 自动格式化能力
    // ★ 不设 ATSH: 让 ATSP6 协议层自动处理 CAN 帧封装

    // ── Phase 3: 读取设备信息 ──
    elmId = (await raw('ATI', timeout: 1.0, silent: true)).trim();
    _log('SYS', '设备: $elmId');

    // ── Phase 4: 验证协议 ──
    protocol = (await raw('ATDP', timeout: 1.0, silent: true)).trim();
    _log('SYS', '协议: $protocol');

    // 检查是否为 ELM327 兼容设备
    _stnAvailable = false;
    _stpxAvailable = false;
    _stbcEnabled = false;
    _stcsegrEnabled = false;

    // 尝试探测 STN 芯片 (可选, 探测失败也不影响 OBD-II 模式)
    try {
      final stiResp = (await raw('STI', timeout: 0.5, silent: true)).trim();
      if (stiResp.isNotEmpty &&
          !stiResp.toUpperCase().contains('?') &&
          !stiResp.toUpperCase().contains('ERROR')) {
        _stnAvailable = true;
        _stpxAvailable = true;
        _log('SYS', '✅ STN 芯片: $stiResp');
        // STN 设备也启用 ATS0 (关闭空格以减少传输量)
        await raw('ATS0', silent: true);
      }
    } catch (_) {
      // vLinker MS 等 ELM327 克隆可能不支持 STI
    }

    // ── Phase 5: CAN 总线验证 + 暖机 ──
    _log('SYS', '>>> CAN 总线测试 (0100 暖机)');
    await raw('ATH1', silent: true);  // 确保头部开启

    // 设置 ECU 地址为 OBD-II 广播
    _ecuTx = '7DF';
    _ecuRx = '7E8';

    // 发送 0100 (支持的 PID 00-20) 暖机 + 验证总线
    final canTest = await raw('0100', timeout: 2.0, silent: true);
    if (canTest.contains('NO DATA') || canTest.contains('ERROR') || canTest.isEmpty) {
      _log('ERR', 'CAN 总线无响应 — 检查 OBD 接口');
      return;
    }
    _log('SYS', 'CAN OK — OBD-II 总线就绪');

    // ── Phase 6: 读取 VIN → 自动匹配车辆配置 ──
    await _readVinObd2();

    // ── Phase 7: 等待 ECU 稳定 ──
    await Future.delayed(const Duration(milliseconds: 300));

    _log('SYS', '✅ OBD-II 握手成功');
  }

  /// 底层 header 设置 (不经过缓存, 仅 ATSH + ATCRA)
  Future<void> _setHeaderRaw(String tx, String rx) async {
    if (_stbcEnabled && rx.isNotEmpty) {
      // ★ STBC: 合并 2 条命令为 1 次蓝牙往返
      await raw('ATSH$tx|ATCRA$rx', silent: true);
    } else {
      await raw('ATSH$tx', silent: true);
      if (rx.isNotEmpty) {
        await raw('ATCRA$rx', silent: true);
      } else {
        await raw('ATCRA', silent: true);
      }
    }
    _lastTx = ''; // 清缓存
  }

  // ═══════════════════════════════════════════════════════════════
  // 底层收发
  // ═══════════════════════════════════════════════════════════════

  Future<String> raw(String cmd, {double timeout = 2.0, bool silent = false}) async {
    if (_transport == null || !isConnected) return '';
    try {
      // ★ 模式标签: O=OBD-II, U=UDS
      final tagPrefix = commMode == CommMode.obd2 ? 'O' : 'U';
      if (!silent) _log('TX-$tagPrefix', cmd);

      final t0 = rawTraceEnabled ? DateTime.now() : null;
      _tr('TX-$tagPrefix  $cmd');

      _rxBuf.clear();
      _rxGotPrompt = false;
      _rxCompleter = Completer<String>();

      await _transport!.write(Uint8List.fromList('$cmd\r'.codeUnits));

      final result = await _rxCompleter!.future.timeout(
        Duration(milliseconds: (timeout * 1000).round()),
        onTimeout: () => _rxBuf.toString(),
      );

      final resp = result.replaceAll('\r', '\n');
      final lines = resp.split('\n')
          .map((l) => l.trim().replaceAll('>', '').trim())
          .where((l) => l.isNotEmpty && l != cmd && l != cmd.replaceAll(' ', ''))
          .toList();
      final cleaned = lines.join('\n').trim();

      if (t0 != null) {
        final dt = DateTime.now().difference(t0).inMilliseconds;
        _tr('RX-$tagPrefix  ${dt}ms  ${cleaned.length > 80 ? '${cleaned.substring(0, 80)}...' : cleaned}');
      }

      if (!silent && cleaned.isNotEmpty) _log('RX-$tagPrefix', cleaned);
      return cleaned;
    } catch (e) {
      _tr('ERR $e');
      _log('ERR', 'IO Error: $e');
      return '';
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UDS — 数据读取
  // ═══════════════════════════════════════════════════════════════

  /// 设置 CAN 收发地址 (带缓存, 目标不变时跳过)
  /// 流控已在 _initUds 中设置一次, 这里只需 ATSH + ATCRA
  Future<void> setHeader(String tx, [String rx = '']) async {
    final key = '${tx}_$rx';
    if (_lastTx == key) return; // ★ 目标 ECU 未变, 跳过
    if (_stbcEnabled && rx.isNotEmpty) {
      // ★ 合并为 1 次蓝牙往返
      await raw('ATSH$tx|ATCRA$rx', silent: true);
    } else {
      await raw('ATSH$tx', silent: true);
      if (rx.isNotEmpty) {
        await raw('ATCRA$rx', silent: true);
      } else {
        await raw('ATCRA', silent: true);
      }
    }
    _lastTx = key;
  }

  /// UDS 原子操作: setHeader + 发送命令 + 解析
  /// ★ 智能路径选择:
  ///   - header 缓存命中 → raw hex (最快, 0 额外开销)
  ///   - header 缓存未命中 + STPX → STPX 内联 (省 ATSH+ATCRA 2 次往返)
  ///   - header 缓存未命中 + 无 STPX → setHeader + raw hex
  Future<List<int>?> sendUdsData(
    String tx, String rx, String hexCmd,
    {double timeout = 3.0}
  ) async {
    if (!isConnected || commMode != CommMode.uds) return null;
    final effectiveTx = tx.isNotEmpty ? tx : _ecuTx;
    final effectiveRx = rx.isNotEmpty ? rx : _ecuRx;

    return _busLock.run(() async {
      final headerKey = '${effectiveTx}_$effectiveRx';
      final headerCached = (_lastTx == headerKey);
      final cmd = hexCmd.replaceAll(' ', '');

      if (headerCached) {
        // ★ 缓存命中: raw hex 直通 (最快路径, 0 额外往返)
        final resp = await raw(cmd, timeout: timeout, silent: true);
        return _parseUdsDataResponse(resp);
      }

      if (_stpxAvailable) {
        // ★ 缓存未命中 + STPX: 内联 header (省 ATSH+ATCRA 2 次往返)
        // STPX 不修改全局 ATSH/ATCRA → 不清除 _lastTx
        final timeoutMs = (timeout * 1000).round();
        final resp = await raw(
          'STPX H:$effectiveTx, D:$cmd, T:$timeoutMs, R:1',
          timeout: timeout + 0.5, silent: true,
        );
        return _parseUdsDataResponse(resp);
      }

      // ★ 标准路径: setHeader + raw hex
      await setHeader(effectiveTx, effectiveRx);
      final resp = await raw(cmd, timeout: timeout, silent: true);
      return _parseUdsDataResponse(resp);
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // OBD-II Mode 01 PID 读取
  // ═══════════════════════════════════════════════════════════════

  /// 发送 OBD-II Mode 01 PID 请求并解析响应
  ///
  /// 请求格式: 01 PID (如 '010C' 读 RPM)
  /// 响应格式: 7E8 03 41 PID [data...]
  ///
  /// 支持:
  ///   - ATS0 (无空格): "7E803410CABCD" → 跳过 7E8+03, 解析 41 0C AB CD
  ///   - ATS1 (有空格): "7E8 03 41 0C AB CD" → 压缩空格后同上
  ///   - ELM327 多行响应 (含回显行)
  ///
  /// ★ 热路径优化: ELM327 自动处理 CAN 封装, 无需手动设 header
  Future<List<int>?> sendObd2Pid(
    ObdPid pid,
    {double timeout = 0.3}
  ) async {
    if (!isConnected || commMode != CommMode.obd2) return null;
    if (!pid.hasObd2) return null;

    final cmd = pid.obd2Cmd;
    if (cmd.isEmpty) return null;

    return _busLock.run(() async {
      obd2CallCount++;
      // ★ 前 80 次 (≈5 周期): 全量 TX/RX 记录
      //    80-800: 仅失败时记录
      //    >800: 每 160 次记录一次心跳
      final verbose = obd2CallCount <= 80;
      final logFailure = obd2CallCount <= 800;
      final heartbeat = obd2CallCount > 80 && obd2CallCount % 160 == 0;

      final t0 = DateTime.now();
      final resp = await raw(cmd, timeout: timeout, silent: !verbose);
      final elapsedUs = DateTime.now().difference(t0).inMicroseconds;

      final data = _parseObd2Response(resp, pid);

      if (verbose) {
        // 全量日志: 每次 TX/RX + 耗时
        _log('OBD2', '#$obd2CallCount ${pid.shortName} ${elapsedUs ~/ 1000}ms → ${data != null ? "${data.length}B" : resp.isEmpty ? "TIMEOUT" : "PARSE_FAIL"}');
      } else if (data == null && logFailure) {
        _log('OBD2', '#$obd2CallCount ${pid.shortName} FAIL ${resp.isEmpty ? "TIMEOUT" : resp.length > 40 ? "${resp.substring(0,40)}..." : resp}');
      } else if (heartbeat) {
        _log('OBD2', '#$obd2CallCount heartbeat (OK)');
      }

      // ★ 记录 per-PID 耗时供 LiveDataService 汇总
      _lastObd2ElapsedUs = elapsedUs;

      return data;
    });
  }

  int obd2CallCount = 0;  // OBD-II 调用计数器
  int _lastObd2ElapsedUs = 0;  // 最近一次 PID 耗时 (微秒)

  /// 解析 OBD-II Mode 01 响应
  ///
  /// 响应格式:
  ///   ATS1: "7E8 03 41 0C AB CD"     (空格分隔, CAN ID + PCI + SID + PID + 数据)
  ///   ATS0: "7E803410CABCD"          (无空格, 连续 hex)
  ///
  /// 返回: 数据字节列表 (不含 CAN ID、PCI、SID 41、PID echo)
  ///   例: 41 0C AB CD → [0xAB, 0xCD]
  List<int>? _parseObd2Response(String rawResp, ObdPid pid) {
    if (rawResp.isEmpty) return null;

    // 检查错误
    for (final err in ['ERROR', 'NO DATA', 'UNABLE', 'CAN ERROR', 'SEARCHING']) {
      if (rawResp.toUpperCase().contains(err)) return null;
    }

    // 去除回显行 (命令本身)
    final cmdStr = pid.obd2Cmd;
    final lines = rawResp.split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.toUpperCase().contains(cmdStr))
        .toList();

    if (lines.isEmpty) return null;

    // 取最后一行有效响应 (可能有多个 ECU 响应, ECM 是 7E8)
    String? targetLine;
    for (var i = lines.length - 1; i >= 0; i--) {
      final merged = lines[i].replaceAll(' ', '');
      // ATS1: "7E8 03 41 0C ..." → "7E803410C..."
      // ATS0: "7E803410C..."
      if (merged.length >= 6 &&
          (merged.startsWith('7E8') || merged.startsWith('7e8'))) {
        targetLine = merged;
        break;
      }
      // 也匹配无 CAN ID 的行 (某些适配器已剥离, 仅匹配 SID 41)
      if (merged.length >= 4 && merged.startsWith('41')) {
        targetLine = merged;
        break;
      }
    }

    if (targetLine == null || targetLine.length < 6) return null;

    // 解析 hex 字节
    String hex = targetLine;
    // 跳过 CAN ID (3 char for 11-bit) 如果存在
    if (hex.startsWith('7E8') || hex.startsWith('7e8')) {
      hex = hex.substring(3);
    }

    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final c0 = hex.codeUnitAt(i);
      final c1 = hex.codeUnitAt(i + 1);
      if (c0 >= _hexLut.length || c1 >= _hexLut.length) break;
      final h = _hexLut[c0];
      final l = _hexLut[c1];
      if (h < 0 || l < 0) break;
      bytes.add((h << 4) | l);
    }

    if (bytes.isEmpty) return null;

    // 查找 SID 41 和 PID echo
    // 格式: [PCI] 41 [PID] [data...]
    // PCI: 通常为 03 (单帧, 3 字节数据), 但可能被 ELM327 剥离
    int sidIdx = -1;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x41) {
        sidIdx = i;
        break;
      }
    }

    if (sidIdx < 0 || sidIdx + 2 > bytes.length) return null;

    // 验证 PID echo
    final pidByte = int.tryParse(pid.obd2Pid, radix: 16);
    if (pidByte != null &&
        sidIdx + 1 < bytes.length &&
        bytes[sidIdx + 1] != pidByte) {
      // PID 不匹配, 可能是其他 ECU 的响应
      return null;
    }

    // 返回数据字节 (41 PID 之后)
    final dataStart = sidIdx + 2;
    if (dataStart >= bytes.length) return null;
    return bytes.sublist(dataStart);
  }

  // ═══════════════════════════════════════════════════════════════
  // ★ Multi-DID 批量读取 — 一个请求读多个 DID
  // ═══════════════════════════════════════════════════════════════

  /// ★★★ Tier 3 批量读取: N 个 STPX 命令通过 STBC 合并为 1-2 次蓝牙往返 ★★★
  /// 返回: {pidId: rawBytes} — 与 sendUdsMultiDid 相同格式
  /// 适用于 ECU 不支持 Multi-DID 但适配器有 STBC 的场景
  Future<Map<String, List<int>>?> sendUdsDataBatchStpx(
    List<ObdPid> pids,
    {double timeout = 2.0}
  ) async {
    if (!isConnected || !_stpxAvailable || !_stbcEnabled || pids.isEmpty) return null;

    return _busLock.run(() async {
      final results = <String, List<int>>{};

      // ★ 构建批量 STPX 命令 (管道分隔)
      // 每个 STPX 约 30 字符, STBC 缓冲 1024 字符 → 最多 ~30 个/批
      const maxPerBatch = 25;
      for (var start = 0; start < pids.length; start += maxPerBatch) {
        final end = (start + maxPerBatch).clamp(0, pids.length);
        final batch = pids.sublist(start, end);

        final stpxT = _profile?.stpxCmdTimeout ?? 150;
        final cmds = batch.map((pid) {
          final cmd = pid.udsCmd.replaceAll(' ', '');
          return 'STPX H:$_ecuTx, D:$cmd, T:$stpxT, R:1';
        }).join('|');

        final resp = await raw(cmds, timeout: timeout + 1.0, silent: true);
        if (resp.isEmpty) continue;

        // ★ STBCOF 1 格式: 响应之间无 OK, 用管道或换行分隔
        // 解析每个子响应
        final subResponses = resp.split(RegExp(r'[|\n]'));
        var pidIdx = 0;
        for (final sub in subResponses) {
          final trimmed = sub.trim();
          if (trimmed.isEmpty) continue;
          if (pidIdx >= batch.length) break;

          final data = _parseUdsDataResponse(trimmed);
          if (data != null && data.isNotEmpty && data[0] == 0x62 && data.length >= 3) {
            results[batch[pidIdx].id] = data.sublist(3);
          }
          pidIdx++;
        }
      }

      // STPX 不修改全局 ATSH/ATCRA → 不清除 _lastTx
      return results.isEmpty ? null : results;
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // ★★ sendUdsMultiDid — SID 0x22 Multi-DID 批量读取
  // ═══════════════════════════════════════════════════════════════
  //
  //  请求: 22 DID1_HI DID1_LO DID2_HI DID2_LO ...
  //  响应: 62 DID1_HI DID1_LO [data1] DID2_HI DID2_LO [data2] ...
  //
  //  将 7 次往返 (7 × 58ms = 406ms) 压缩为 1 次 (~100ms)
  //

  /// Multi-DID 批量读取 (单锁 + 流式分批)
  /// 所有批次共享一次 busLock + 一次 setHeader → 最小化开销
  /// ★ 使用 raw hex + header 缓存 (非 STPX):
  ///   - 目标 ECU 固定 → header 缓存命中
  ///   - STCSEGR 处理多帧拼包
  ///   - 不破坏 _lastTx 缓存
  Future<Map<String, List<int>>?> sendUdsMultiDid(
    List<ObdPid> pids,
    {double timeout = 3.0, bool debug = false}
  ) async {
    if (!isConnected || commMode != CommMode.uds || pids.isEmpty) return null;

    final validPids = pids.where((p) => p.udsDid.length >= 4).toList();
    if (validPids.isEmpty) return null;

    final batchSize = _multiDidMax >= 99 ? validPids.length : _multiDidMax.clamp(1, 3);

    // ★ 单次 busLock — 所有批次在一个原子操作内完成
    return _busLock.run<Map<String, List<int>>?>(() async {
      await setHeader(_ecuTx, _ecuRx); // ★ 缓存命中时 cost = 0

      final allResults = <String, List<int>>{};

      for (var start = 0; start < validPids.length; start += batchSize) {
        final end = (start + batchSize).clamp(0, validPids.length);
        final batch = validPids.sublist(start, end);

        // 构建请求 (无空格 → 省 BLE 字节)
        final sb = StringBuffer('22');
        for (final pid in batch) {
          sb.write(pid.udsDid.substring(0, 2));
          sb.write(pid.udsDid.substring(2, 4));
        }

        final resp = await raw(sb.toString().toUpperCase(),
            timeout: timeout, silent: true);
        if (debug) _log('DBG', '批次[$start~$end]: ${resp.isEmpty ? "无响应" : "已收到"}');

        final data = _parseUdsDataResponse(resp);
        if (data == null || data.isEmpty || data[0] != 0x62) continue;

        // 顺序扫描解析
        final foundPositions = <int>[];
        var searchFrom = 1;
        for (final pid in batch) {
          final didInt = int.parse(pid.udsDid, radix: 16);
          final didHi = (didInt >> 8) & 0xFF;
          final didLo = didInt & 0xFF;
          var found = false;
          for (var i = searchFrom; i < data.length - 1; i++) {
            if (data[i] == didHi && data[i + 1] == didLo) {
              foundPositions.add(i);
              searchFrom = i + 2;
              found = true;
              break;
            }
          }
          if (!found) foundPositions.add(-1);
        }

        for (var i = 0; i < batch.length; i++) {
          final pos = foundPositions[i];
          if (pos < 0) continue;
          final dataStart = pos + 2;
          int dataEnd = data.length;
          for (var j = i + 1; j < foundPositions.length; j++) {
            if (foundPositions[j] >= 0) { dataEnd = foundPositions[j]; break; }
          }
          if (dataStart < dataEnd && dataStart < data.length) {
            allResults[batch[i].id] = data.sublist(dataStart, dataEnd);
          }
        }
      }

      if (debug) {
        _log('DBG', '批量读取: ${allResults.length}/${validPids.length} '
            '(${(validPids.length / batchSize).ceil()}批×$batchSize)');
      }
      return allResults.isEmpty ? null : allResults;
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // ★★★ SID 0x2C — 动态组合 DID (20 Hz 高频采集核心)
  // ═══════════════════════════════════════════════════════════════
  //
  //  ISO 14229-1 DynamicallyDefineDataIdentifier:
  //    0x2C 0x01 = defineByIdentifier (创建)
  //    0x2C 0x03 = clear (清除)
  //  将多个源 DID 焊接为一个虚拟 DID (0xF300)
  //  每次轮询只需 1 次 22 F3 00 → 50ms → 20 Hz
  //

  /// 清除指定的动态 DID 定义
  /// [targetDid] — 虚拟 DID 地址 (如 0xF300)
  Future<bool> clearDynamicDid(String ecuTx, String ecuRx, int targetDid) async {
    if (!isConnected || commMode != CommMode.uds) return false;
    return _busLock.run(() async {
      await setHeader(ecuTx, ecuRx);
      final targetH = (targetDid >> 8) & 0xFF;
      final targetL = targetDid & 0xFF;
      final hexData = '2C 03 '
          '${targetH.toRadixString(16).padLeft(2, '0')} '
          '${targetL.toRadixString(16).padLeft(2, '0')}'.toUpperCase();

      _log('SYS', '  清除动态组合定义');

      // ★ 优先 STPX (统一通路), 否则标准 AT
      String resp;
      if (_stpxAvailable) {
        resp = await raw('STPX H:$ecuTx, D:$hexData', timeout: 2.0, silent: true);
      } else {
        resp = await raw(hexData, timeout: 2.0, silent: true);
      }

      final data = _parseUdsDataResponse(resp);
      // 正响应: 6C 03 [targetH] [targetL]
      if (data != null && data.isNotEmpty && data[0] == 0x6C) {
        _log('SYS', '  ✅ 清除成功');
        return true;
      }
      // NRC 0x31 也视为"已清除" (可能本来就没定义)
      if (resp.toUpperCase().contains('7F 2C 31') ||
          (data != null && data.length >= 3 && data[0] == 0x7F && data[2] == 0x31)) {
        _log('SYS', '  ⚠ 可能本就未定义, 继续');
        return true;
      }
      _log('SYS', '  ❌ 清除失败: $resp');
      return false;
    });
  }

  /// 创建动态组合 DID — SID 0x2C subFunc 0x01 (defineByIdentifier)
  ///
  /// [targetDid] — 虚拟 DID 地址 (如 0xF300)
  /// [sources] — 源 DID 定义列表
  ///
  /// ★ 发送策略:
  ///   payload ≤ 7 字节 → 标准 ELM327 单帧
  ///   payload > 7 字节 → STPX (STN 原生 ISO-TP 多帧)
  ///   STPX 不可用时 → ELM327 AT AL 自动分帧 (可能失败)
  Future<bool> sendUdsDynamicDefine(
    String ecuTx, String ecuRx,
    int targetDid,
    List<DynamicDidSource> sources,
  ) async {
    if (!isConnected || commMode != CommMode.uds) return false;
    if (sources.isEmpty) return false;

    return _busLock.run(() async {
      await setHeader(ecuTx, ecuRx);

      // ── Step 1: 清除旧定义 (在锁内直接操作) ──
      final targetH = (targetDid >> 8) & 0xFF;
      final targetL = targetDid & 0xFF;

      // 清除: 优先 STPX, 否则标准 AT
      String clearResp;
      if (_stpxAvailable) {
        clearResp = await raw(
          'STPX H:$ecuTx, D:2C 03 '
          '${targetH.toRadixString(16).padLeft(2, '0')} '
          '${targetL.toRadixString(16).padLeft(2, '0')}',
          timeout: 2.0, silent: true);
      } else {
        clearResp = await raw(
          '2C 03 '
          '${targetH.toRadixString(16).padLeft(2, '0')} '
          '${targetL.toRadixString(16).padLeft(2, '0')}'.toUpperCase(),
          timeout: 2.0, silent: true);
      }
      // 忽略清除结果 (NRC 0x31 = 本就没定义, 不影响后续创建)
      _log('SYS', '  清除旧定义: ${clearResp.contains('6C') ? "✅" : "⚠ 继续"}');

      await Future.delayed(const Duration(milliseconds: 100));

      // ── Step 2: 构建定义 UDS 负载 ──
      // 负载: 2C 01 [targetH] [targetL] [src1_H src1_L pos size] ...
      final hexParts = <String>[
        '2C', '01',
        targetH.toRadixString(16).padLeft(2, '0'),
        targetL.toRadixString(16).padLeft(2, '0'),
      ];
      for (final src in sources) {
        for (final b in src.defineBytes) {
          hexParts.add(b.toRadixString(16).padLeft(2, '0'));
        }
      }
      final payloadHex = hexParts.join(' ').toUpperCase();
      final payloadLen = hexParts.length; // 字节数

      _log('SYS', '  定义动态组合: $payloadLen 字节, ${sources.length} 个源');

      // ── Step 3: 发送定义命令 ──
      String resp;
      if (payloadLen <= 7) {
        // 单帧: 标准 ELM327 即可
        _log('SYS', '  → 单帧发送');
        resp = await raw(payloadHex, timeout: 5.0, silent: true);
      } else if (_stpxAvailable) {
        // ★★★ 多帧: 使用 STPX (STN 原生 ISO-TP 多帧) ★★★
        // STPX 自动处理: First Frame → 等待 Flow Control → Consecutive Frames
        // H: 设置发送 CAN ID, STPX 自动监听 H+8 的响应
        _log('SYS', '  → 多帧高速通道发送');
        resp = await raw('STPX H:$ecuTx, D:$payloadHex', timeout: 5.0, silent: true);
      } else {
        // 降级: ELM327 AT AL 自动分帧 (部分设备不支持)
        _log('SYS', '  → 多帧兼容通道发送');
        resp = await raw(payloadHex, timeout: 5.0, silent: true);
      }

      final data = _parseUdsDataResponse(resp);

      // 正响应: 6C 01 [targetH] [targetL]
      if (data != null && data.isNotEmpty && data[0] == 0x6C && data[1] == 0x01) {
        _log('SYS', '  ✅ 动态组合定义成功');
        return true;
      }

      // 错误处理
      if (data != null && data.length >= 3 && data[0] == 0x7F) {
        final nrc = data[2];
        final nrcName = switch (nrc) {
          0x31 => '参数范围不支持',
          0x22 => '当前条件不满足 (可能需要扩展会话)',
          0x33 => '安全权限不足',
          0x72 => '定义表已满',
          _ => '错误代码 ${nrc.toRadixString(16)}',
        };
        _log('ERR', '  ❌ 动态组合定义失败: $nrcName');
      } else {
        _log('ERR', '  ❌ 动态组合定义失败');
      }
      return false;
    });
  }

  /// 读取动态组合 DID — 普通 SID 0x22 读取
  /// 返回纯数据负载 (不含 62 F3 00 前缀)
  /// ★ 这是 Tier 1 热路径, 每秒调用 12-20 次, 必须极致优化
  ///
  /// ★★★ 热路径优化:
  ///   - 命令字节预缓存 (避免每周期 5 次 String 分配)
  ///   - header 缓存命中 → raw hex (最快, 0 额外开销)
  ///   - STCSEGR 已在芯片端处理多帧拼包
  Future<List<int>?> readDynamicDid(int targetDid, {double timeout = 0.5}) async {
    if (!isConnected || commMode != CommMode.uds) return null;
    return _busLock.run(() async {
      await setHeader(_ecuTx, _ecuRx); // ★ 缓存命中时 cost = 0

      // ★ 命令字节缓存: R1避免每周期重建 "22F300"
      // ★ T 参数从 profile 读取 (默认 50ms)
    _dynDidCmdBytes ??= Uint8List.fromList(
        'STPX H:$_ecuTx, D:22${targetDid.toRadixString(16).padLeft(4, '0').toUpperCase()}, T:${_profile?.dynDidReadTimeout ?? 50}, R:1\r'.codeUnits,
      );

      final t0 = rawTraceEnabled ? DateTime.now() : null;
      _tr('TX  22F300');

      // ★ 内联 raw() 热路径: 跳过 silent/log 分支 + 减少 String 分配
      _rxBuf.clear();
      _rxGotPrompt = false;
      _rxCompleter = Completer<String>();

      await _transport!.write(_dynDidCmdBytes!);

      final result = await _rxCompleter!.future.timeout(
        Duration(milliseconds: (timeout * 1000).round()),
        onTimeout: () => _rxBuf.toString(),
      );

      // ★ 简化解析: silent 模式不需要过滤回显 (ATE0 已关)
      final cleaned = result.replaceAll('\r', '\n')
          .split('\n')
          .map((l) => l.trim().replaceAll('>', '').trim())
          .where((l) => l.isNotEmpty)
          .join('\n')
          .trim();

      if (t0 != null) {
        final dt = DateTime.now().difference(t0).inMilliseconds;
        _tr('RX  ${dt}ms  ${cleaned.length > 80 ? '${cleaned.substring(0, 80)}...' : cleaned}');
      }

      final data = _parseUdsDataResponse(cleaned);
      if (data == null || data.length < 3 || data[0] != 0x62) {
        _tr('FAIL  parse=${data?.length ?? -1}');
        return null;
      }
      // 验证 DID echo
      final echoH = data[1];
      final echoL = data[2];
      if (echoH != ((targetDid >> 8) & 0xFF) || echoL != (targetDid & 0xFF)) {
        _tr('FAIL  echo');
        return null;
      }
      return data.sublist(3); // 返回纯数据负载
    });
  }


  /// 测试 ECU Multi-DID 支持 — 精确探测上限
  /// 返回: true=支持, _multiDidMax=实际 DID/请求上限
  int _multiDidMax = 0;

  Future<bool> testMultiDidSupport() async {
    if (!isConnected || commMode != CommMode.uds) return false;
    _multiDidMax = 0;

    try {
      // 阶段 1: 2 DID (5字节, 单帧)
      var resp = await _busLock.run<String>(() async {
        await setHeader(_ecuTx, _ecuRx);
        return await raw('22 20 00 20 11', timeout: 2.0, silent: true);
      });
      var data = _parseUdsDataResponse(resp);
      if (data == null || data.isEmpty || data[0] != 0x62 || data.length < 6) return false;
      _multiDidMax = 2;

      // 阶段 2: 3 DID (7字节, 单帧极限)
      resp = await _busLock.run<String>(() async {
        await setHeader(_ecuTx, _ecuRx);
        return await raw('22 20 00 20 11 20 77', timeout: 2.0, silent: true);
      });
      data = _parseUdsDataResponse(resp);
      if (data != null && data.isNotEmpty && data[0] == 0x62 && data.length >= 8) {
        _multiDidMax = 3;
      }

      // 阶段 3: 4 DID (9字节, 需 ISO-TP + AT AL)
      if (_multiDidMax >= 3) {
        resp = await _busLock.run<String>(() async {
          await setHeader(_ecuTx, _ecuRx);
          return await raw('22 20 00 20 11 20 77 60 00', timeout: 2.0, silent: true);
        });
        data = _parseUdsDataResponse(resp);
        if (data != null && data.isNotEmpty && data[0] == 0x62 && data.length >= 12) {
          _multiDidMax = 99; // AT AL 多帧 OK
          _log('SYS', '  批量查询: 多帧正常');
        }
      }

      _log('SYS', '  批量查询: 最大 $_multiDidMax 参数/请求');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// UDS 响应解析 (ISO-TP 单帧/多帧重组)
  /// ★ 支持 ATS0 (无空格) 和 ATS1 (有空格) 两种格式
  ///
  /// 三层解析策略:
  ///  ① STCSEGR 快速路径: 芯片已拼包, 单行直取 (0 拷贝)
  ///  ② PCI type 0: 标准单帧 (剥 PCI)
  ///  ③ PCI type 1: 首帧+连续帧手动重组 (STCSEGR 关闭时)
  ///  ④ 兜底: 非标准格式尝试直取 (防御性)
  List<int>? _parseUdsDataResponse(String rawResp) {
    if (rawResp.isEmpty) return null;
    for (final err in ['ERROR', 'NO DATA', 'UNABLE', 'CAN ERROR']) {
      if (rawResp.toUpperCase().contains(err)) return null;
    }

    final allFrames = <List<int>>[];
    for (final line in rawResp.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final bytes = _parseHexLine(trimmed);
      if (bytes.isNotEmpty) allFrames.add(bytes);
    }
    if (allFrames.isEmpty) return null;

    final first = allFrames[0];
    if (first.isEmpty) return null;
    final firstByte = first[0];
    final highNibble = (firstByte >> 4) & 0x0F;

    // ═══ ① STCSEGR 快速路径 ═══
    //
    // STCSEGR 1 启用后, 芯片自动重组多帧 RX:
    //   - 剥离所有 PCI 字节 (FF/CF)
    //   - 拼接为单条消息输出
    //   - 首字节 = UDS SID (正响应 ≥0x40, NRC=0x7F)
    //
    // 单帧不受 STCSEGR 影响 → PCI 仍存在 → highNibble=0 → 走 ② 路径
    // 多帧 STCSEGR 拼包后 → 首字节是 SID → highNibble ≥ 4 → 走这里
    //
    // 安全判定: UDS 正响应 SID ∈ [0x41..0x7F], NRC=0x7F
    //           PCI type ∈ [0..2] → highNibble ∈ [0..2]
    //           无重叠 → 判定可靠
    if (_stcsegrEnabled && allFrames.length == 1 && highNibble > 2) {
      // NRC 检测 (虽然 NRC 通常是单帧, 防御性处理)
      if (firstByte == 0x7F) {
        if (first.length >= 3 && first[2] == 0x78) return null; // responsePending
        return null;
      }
      return first; // ★ 已拼包 UDS payload, 直接返回
    }

    // ═══ ② 单帧: PCI type 0 ═══
    if (highNibble == 0) {
      final data = first.sublist(1);
      if (data.isEmpty) return null;
      if (data[0] == 0x7F) {
        if (data.length >= 3 && data[2] == 0x78) return null; // responsePending
        return null;
      }
      return data;
    }

    // ═══ ③ 首帧 + 连续帧: PCI type 1 (STCSEGR 关闭时的降级路径) ═══
    if (highNibble == 1) {
      if (first.length < 2) return null;
      final totalLen = ((firstByte & 0x0F) << 8) | first[1];
      final payload = <int>[];
      for (var i = 2; i < first.length; i++) {
        payload.add(first[i]);
      }
      for (var fi = 1; fi < allFrames.length; fi++) {
        final cf = allFrames[fi];
        if (cf.isEmpty || ((cf[0] >> 4) & 0x0F) != 2) continue;
        for (var i = 1; i < cf.length; i++) {
          payload.add(cf[i]);
        }
      }
      if (payload.length > totalLen) payload.removeRange(totalLen, payload.length);
      if (payload.isEmpty || payload[0] == 0x7F) return null;
      return payload;
    }

    // ═══ ④ 兜底: 非标准格式 ═══
    // 防御: STCSEGR 标记为 false 但实际已生效 (固件 quirk)
    // 或 STPX 内部临时启用拼包产生的已组装输出
    if (allFrames.length == 1 && highNibble > 2) {
      if (firstByte == 0x7F) return null;
      return first;
    }

    return null;
  }

  /// ★ 公开 hex 响应解析 (供 DID 扫描器等使用)
  /// 返回完整字节列表 (跳过 CAN ID, 保留 PCI + SID + data)
  static List<int>? parseHexResponse(String rawResp) {
    if (rawResp.isEmpty) return null;
    for (final err in ['ERROR', 'NO DATA', 'UNABLE', 'CAN ERROR']) {
      if (rawResp.toUpperCase().contains(err)) return null;
    }
    // 取最后一行有效 hex
    String? targetLine;
    for (final line in rawResp.split('\n').reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final merged = trimmed.replaceAll(' ', '');
      if (merged.length >= 6 &&
          _hexCharRegExp.hasMatch(merged) &&
          (merged.startsWith('7E8') || merged.startsWith('7E0') ||
           merged.startsWith('7EA') || merged.startsWith('62'))) {
        targetLine = merged;
        break;
      }
    }
    if (targetLine == null) return null;

    String hex = targetLine;
    if (hex.length >= 3 && (hex.startsWith('7E8') || hex.startsWith('7E0') || hex.startsWith('7EA'))) {
      hex = hex.substring(3);
    }
    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final c0 = hex.codeUnitAt(i);
      final c1 = hex.codeUnitAt(i + 1);
      if (c0 >= _hexLut.length || c1 >= _hexLut.length) break;
      final h = _hexLut[c0];
      final l = _hexLut[c1];
      if (h < 0 || l < 0) break;
      bytes.add((h << 4) | l);
    }
    return bytes.isEmpty ? null : bytes;
  }

  /// ★ 通用 hex 行解析器 — 统一处理所有格式
  ///
  /// 支持的输入格式:
  ///   ATS1:    "7E8 06 62 20 00 AB CD"         (空格分隔 2-char 字节)
  ///   ATS0:    "7E80662200ABCD"                 (连续 hex)
  ///   STCSEGR: "7E862F300AABB 1122334455 6677"  (拼包段之间有空格, 每段 >2 chars)
  ///
  /// 策略: 先去空格合并为连续 hex, 再统一按 ATS0 逻辑解析
  /// 这样 ATS1 的 "7E8 06 62" → "7E80662" 和 ATS0 的 "7E80662" 走同一条路径
  static List<int> _parseHexLine(String line) {
    // 去除所有空格, 合并为连续 hex 字符串
    final merged = line.replaceAll(' ', '');
    if (merged.isEmpty) return [];

    // 只接受纯 hex 字符串 (★ 使用预编译 RegExp)
    if (!_hexCharRegExp.hasMatch(merged)) return [];

    String hex = merged;
    // 11-bit CAN + ATH1: 总长度为奇数 (3 char ID + 2N char 数据)
    // 29-bit CAN + ATH1: 总长度为偶数 (8 char ID + 2N char 数据)
    if (hex.length >= 5 && hex.length.isOdd) {
      // 跳过 3-char CAN ID (11-bit: 7E8, 7EA, 7DF 等)
      hex = hex.substring(3);
    } else if (hex.length >= 10 && hex.length.isEven) {
      // 检查 29-bit CAN ID 特征 (18xx / 1Cxx)
      final hi = hex.substring(0, 2).toUpperCase();
      if (hi == '18' || hi == '1C') {
        hex = hex.substring(8);
      }
    }

    // 解析 hex 字节对 (★ 使用查找表, 避免 int.parse 开销)
    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final c0 = hex.codeUnitAt(i);
      final c1 = hex.codeUnitAt(i + 1);
      if (c0 >= _hexLut.length || c1 >= _hexLut.length) break;
      final h = _hexLut[c0];
      final l = _hexLut[c1];
      if (h < 0 || l < 0) break;
      bytes.add((h << 4) | l);
    }
    return bytes;
  }

  // ── UDS 会话管理 ──

  /// 确保 UDS 扩展会话存在 (通常已在 _initUds 中建立)
  Future<bool> ensureSession(String tx, String rx) async {
    if (commMode != CommMode.uds) return true;
    if (_sessions.contains(tx.toUpperCase())) return true;
    // 会话不存在 — 重新建立
    return _busLock.run(() async {
      await setHeader(tx, rx);
      await Future.delayed(const Duration(milliseconds: 100));
      // ★ 使用 profile 首选会话类型 (默认 10 03)
      final sessPref = _profile?.sessionPreferred ?? '03';
      final resp = await raw('10 $sessPref', timeout: 3.0, silent: true);
      if (resp.isEmpty || resp.toUpperCase().contains('ERROR') ||
          resp.toUpperCase().contains('NO DATA')) {
        _log('ERR', '会话建立失败');
        return false;
      }
      _sessions.add(tx.toUpperCase());
      _log('SYS', '✅ 诊断会话已建立');
      // 确保心跳在运行
      if (!hbRunning) startHeartbeat();
      return true;
    });
  }

  // ── 心跳 (仅 UDS) ──
  // ★★★ STPPMA: 芯片端自动发送 3E 00, 完全不占蓝牙带宽 ★★★
  // 旧方案: Timer 每 2 秒 → 2 次 BT 往返 (ATSH + 3E 00) + 破坏 header 缓存
  // 新方案: STPPMA 一次设置, 芯片自主发送, 永远不干扰主通讯通路

  void startHeartbeat() {
    if (hbRunning || commMode != CommMode.uds) return;
    hbRunning = true;
    _log('SYS', '❤️ 心跳启动');
    _notify();

    if (_stnAvailable) {
      // ★ STPPMA: 芯片端周期消息 (2000ms, 3E00 = TesterPresent)
      // 返回句柄 (如 "1"), 用于后续删除
      _setupPeriodicHeartbeat();
    } else {
      // 降级: 传统 Timer 心跳 (非 STN 设备)
      final hbDur = Duration(milliseconds: _profile?.heartbeatInterval ?? 2000);
      _hbTimer = Timer.periodic(hbDur, (_) async {
        if (!isConnected) { stopHeartbeat(); return; }
        await _busLock.run(() async {
          await setHeader(_ecuTx, _ecuRx);
          final resp = await raw('3E00', timeout: 2.0, silent: true);
          if (resp.contains('NO DATA') || resp.contains('ERROR')) {
            _log('ERR', '❤️ 心跳失败 — ECU 无响应');
            _sessions.clear();
            stopHeartbeat();
          }
        });
      });
    }
  }

  Future<void> _setupPeriodicHeartbeat() async {
    try {
      // STPPMA period, header, data → 返回句柄
      // ★ 心跳参数从 profile 读取 (默认: 2000ms, 3E80)
      final hbInterval = _profile?.heartbeatInterval ?? 2000;
      final hbCmd = _profile?.heartbeatCmd ?? '3E80';
      final resp = (await raw('STPPMA $hbInterval, $_ecuTx, $hbCmd',
          timeout: 1.0, silent: true)).trim();
      if (resp.isNotEmpty && !resp.contains('?') && !resp.contains('ERROR')) {
        _periodicHbHandle = resp.split('\n').last.trim();
        _log('SYS', '  ⚡ 芯片端自动心跳已启动 (${hbInterval}ms, $hbCmd)');
      } else {
        _log('SYS', '  ⚠ 芯片心跳不可用, 使用软件心跳');
        _periodicHbHandle = null;
        // 降级 Timer — 间隔从 profile 读取
        final fallbackDuration = Duration(milliseconds: hbInterval);
        _hbTimer = Timer.periodic(fallbackDuration, (_) async {
          if (!isConnected) { stopHeartbeat(); return; }
          await _busLock.run(() async {
            await setHeader(_ecuTx, _ecuRx);
            final resp = await raw('3E00', timeout: 2.0, silent: true);
            if (resp.contains('NO DATA') || resp.contains('ERROR')) {
              _sessions.clear();
              stopHeartbeat();
            }
          });
        });
      }
    } catch (_) {}
  }

  void stopHeartbeat() {
    // ★ 清除芯片端周期消息
    if (_periodicHbHandle != null && isConnected) {
      raw('STPPMD $_periodicHbHandle', silent: true).catchError((_) {});
      _periodicHbHandle = null;
    }
    _hbTimer?.cancel();
    _hbTimer = null;
    hbRunning = false;
    _notify();
  }

  // ═══════════════════════════════════════════════════════════════
  // VIN 读取 (OBD-II Mode 09 PID 02)
  // ═══════════════════════════════════════════════════════════════

  Future<void> _readVinObd2() async {
    _log('SYS', '读取 VIN (OBD-II 0902)...');
    try {
      final resp = await raw('0902', timeout: 3.0, silent: true);
      if (resp.isEmpty || resp.contains('NO DATA') || resp.contains('ERROR')) {
        vin = '';
        _log('SYS', 'VIN 不可用 (0902 无响应)');
        await ProfileManager.instance.autoMatchVin('');
        return;
      }
      // 解析 49 02 01 [VIN ASCII bytes]
      // ATS0 格式: 7E81014490201XXXX...
      // ATS1 格式: 7E8 10 14 49 02 01 XX XX ...
      final merged = resp.replaceAll(' ', '').replaceAll('\n', '').replaceAll('\r', '');
      // 找 490201 标记
      final markerPos = merged.indexOf('490201');
      final vinChars = <int>[];
      if (markerPos >= 0) {
        // 逐字节解析 hex string from markerPos+6
        var i = markerPos + 6;
        while (i + 1 < merged.length) {
          final byte = int.tryParse(merged.substring(i, i + 2), radix: 16);
          if (byte == null) break;
          if (byte >= 0x20 && byte < 0x7F) {
            vinChars.add(byte);
          } else if (byte == 0x00 && vinChars.length >= 10) {
            break; // null terminator after VIN
          }
          i += 2;
          if (vinChars.length >= 17) break;
        }
      }
      if (vinChars.length >= 10) {
        vin = String.fromCharCodes(vinChars)
            .replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
        if (vin.length > 17) vin = vin.substring(0, 17);
        _log('SYS', '✅ VIN: $vin');
      } else {
        vin = '';
        _log('SYS', 'VIN 解析失败 (仅${vinChars.length}字符)');
      }
    } catch (e) {
      vin = '';
      _log('SYS', 'VIN 读取异常: $e');
    }
    // ★ VIN 自动匹配车辆配置
    await ProfileManager.instance.autoMatchVin(vin);
  }

  // ═══════════════════════════════════════════════════════════════
  // VIN 读取 (UDS)
  // ═══════════════════════════════════════════════════════════════

  Future<void> _readVinUds() async {
    _log('SYS', '读取车辆识别码...');
    final data = await sendUdsData(_ecuTx, _ecuRx, '22F190', timeout: 5.0);
    if (data == null || data.length < 4) {
      vin = '';
      _log('SYS', 'VIN 不可用');
      return;
    }
    // 找 62 F1 90 后的数据
    final vinChars = <int>[];
    for (var i = 0; i < data.length - 2; i++) {
      if (data[i] == 0x62 && data[i + 1] == 0xF1 && data[i + 2] == 0x90) {
        for (var j = i + 3; j < data.length; j++) {
          if (data[j] >= 0x20 && data[j] < 0x7F) vinChars.add(data[j]);
        }
        break;
      }
    }
    if (vinChars.length >= 10) {
      vin = String.fromCharCodes(vinChars)
          .replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      if (vin.length > 17) vin = vin.substring(0, 17);
      _log('SYS', '✅ VIN: $vin');
    } else {
      vin = '';
      _log('SYS', 'VIN 解析失败');
    }
    // ★ VIN 自动匹配车辆配置
    await ProfileManager.instance.autoMatchVin(vin);
  }

  // ═══════════════════════════════════════════════════════════════
  // 延迟诊断 — 逐段隔离瓶颈
  // ═══════════════════════════════════════════════════════════════
  //
  //  总延迟 = App处理 + BT传输 + 适配器处理 + CAN总线 + ECU处理
  //
  //  测试 1: BT 纯往返 (AT I — 不经过 CAN, 适配器本地响应)
  //  测试 2: CAN 单帧 (22 20 00 — RPM, 最短 DID)
  //  测试 3: CAN 多帧 (22 F1 90 — VIN, ISO-TP 多帧)
  //  测试 4: 连续轮询 N 次 (模拟实际 HUD 轮询)
  //  测试 5: App 纯开销 (不发命令, 只跑解析逻辑)
  //

  Future<void> runLatencyDiag({int rounds = 10}) async {
    if (!isConnected) { _log('ERR', '未连接, 无法诊断'); return; }

    // ★ 暂停心跳, 避免干扰测量
    final wasHbRunning = hbRunning;
    if (hbRunning) {
      stopHeartbeat();
      _log('SYS', '⏸ 心跳暂停 (诊断期间)');
      await Future.delayed(const Duration(milliseconds: 200));
    }

    _log('SYS', '');
    _log('SYS', '════════════════════════════════════');
    _log('SYS', '  链路性能诊断 ($rounds 轮)');
    _log('SYS', '  链路: ${linkMode == BtLinkMode.ble ? "BLE (低功耗)" : "经典蓝牙"}');
    _log('SYS', '  模式: UDS 诊断协议');
    if (linkMode == BtLinkMode.ble && _transport is BleTransport) {
      final ble = _transport as BleTransport;
      _log('SYS', '  数据包大小: ${ble.negotiatedMtu}  优先级: 高');
    }
    _log('SYS', '════════════════════════════════════');

    // ── 测试 1: BT 纯往返 (不经 CAN) ──
    bool diagMultiOk = false; // 缓存批量查询结果
    double diagBestHz = 0;   // 追踪最佳采样率 (用于 EVA 同步率)
    _log('SYS', '');
    _log('SYS', '▶ 阶段1: 蓝牙链路基准');
    final btTimes = <int>[];
    for (var i = 0; i < rounds; i++) {
      final t0 = DateTime.now();
      await raw('AT I', silent: true);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      btTimes.add(ms);
    }
    final btAvg = btTimes.reduce((a, b) => a + b) / btTimes.length;
    final btMin = btTimes.reduce((a, b) => a < b ? a : b);
    final btMax = btTimes.reduce((a, b) => a > b ? a : b);
    final btMed = _median(btTimes);
    final btP95 = _percentile(btTimes, 95);
    _log('SYS', '  平均 ${btAvg.toStringAsFixed(1)}ms  '
        '中位 ${btMed}ms  波动 ${btP95}ms');
    _log('SYS', '  → 蓝牙 + 适配器基准 (不含车辆总线)');

    // ── 测试 2: CAN 单帧 DID ──
    if (commMode == CommMode.uds) {
      _log('SYS', '');
      _log('SYS', '▶ 阶段2: 单参数查询速度');
      await setHeader(_ecuTx, _ecuRx);
      final canTimes = <int>[];
      for (var i = 0; i < rounds; i++) {
        final t0 = DateTime.now();
        await raw('22 20 00', timeout: 0.8, silent: true);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        canTimes.add(ms);
      }
      final canAvg = canTimes.reduce((a, b) => a + b) / canTimes.length;
      final canMin = canTimes.reduce((a, b) => a < b ? a : b);
      final canMax = canTimes.reduce((a, b) => a > b ? a : b);
      final canMed = _median(canTimes);
      final canP95 = _percentile(canTimes, 95);
      _log('SYS', '  平均 ${canAvg.toStringAsFixed(1)}ms  '
          '中位 ${canMed}ms  波动 ${canP95}ms');
      // ★ 稳定性分析
      if (canMax > canMed * 3) {
        _log('SYS', '  ⚠ 延迟波动较大');
        _log('SYS', '    → ${linkMode == BtLinkMode.ble ? "低功耗蓝牙连接间隔偏大" : "经典蓝牙串口缓冲抖动"}');
      }

      final ecuTime = canAvg - btAvg;
      _log('SYS', '  → ECU 处理耗时: ~${ecuTime.toStringAsFixed(1)}ms');

      // ── 测试 3: CAN 多帧 ──
      _log('SYS', '');
      _log('SYS', '▶ 阶段3: 长数据传输速度');
      final mfTimes = <int>[];
      for (var i = 0; i < (rounds / 2).ceil(); i++) {
        final t0 = DateTime.now();
        await raw('22 F1 90', timeout: 2.0, silent: true);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        mfTimes.add(ms);
      }
      final mfAvg = mfTimes.reduce((a, b) => a + b) / mfTimes.length;
      _log('SYS', '  多帧传输: 平均 ${mfAvg.toStringAsFixed(1)}ms');
      _log('SYS', '  → 多帧开销: ~${(mfAvg - canAvg).toStringAsFixed(1)}ms');

      // ── 测试 4: 模拟 HUD 轮询 (9 DID 连续读) ──
      _log('SYS', '');
      _log('SYS', '▶ 阶段4: 仪表盘模拟 (9参数连续查询)');
      final dids = ['22 20 00', '22 50 21', '22 20 29', '22 20 77',
                     '22 60 00', '22 20 11', '22 20 71', '22 61 31', '22 60 40'];
      final didNames = ['转速', '车速', '油门', '增压',
                         '扭矩', '水温', '油压', '空燃比', '爆震'];
      final cycleTimes = <int>[];
      final perDid = <String, List<int>>{};

      for (var r = 0; r < (rounds / 2).ceil(); r++) {
        final cycleT0 = DateTime.now();
        for (var d = 0; d < dids.length; d++) {
          final t0 = DateTime.now();
          await raw(dids[d], timeout: 0.8, silent: true);
          final ms = DateTime.now().difference(t0).inMilliseconds;
          perDid.putIfAbsent(didNames[d], () => []).add(ms);
        }
        cycleTimes.add(DateTime.now().difference(cycleT0).inMilliseconds);
      }

      final cycleAvg = cycleTimes.reduce((a, b) => a + b) / cycleTimes.length;
      final cycleHz = 1000 / cycleAvg;
      if (cycleHz > diagBestHz) diagBestHz = cycleHz;
      _log('SYS', '  全周期: 平均 ${cycleAvg.toStringAsFixed(0)}ms  '
          '→ ${cycleHz.toStringAsFixed(1)} Hz');
      _log('SYS', '  逐参数延迟:');
      for (final name in didNames) {
        final times = perDid[name]!;
        final avg = times.reduce((a, b) => a + b) / times.length;
        _log('SYS', '    ${'$name:'.padRight(6)} ${avg.toStringAsFixed(0)}ms');
      }

      // ── 测试 5: Multi-DID 批量 (★ 核心优化) ──
      _log('SYS', '');
      _log('SYS', '▶ 阶段5: 批量查询优化');
      final multiOk = await testMultiDidSupport();
      diagMultiOk = multiOk;
      if (multiOk) {
        _log('SYS', '  ✅ ECU 支持批量查询');
        final batchN = _multiDidMax >= 99 ? 9 : _multiDidMax;
        final batches = (9 / batchN).ceil();
        _log('SYS', '  模式: ${_multiDidMax >= 99 ? "全批量" : "$batchN 参数/帧 → $batches 批/周期"}');

        // ★ 与实际 HUD requiredPidIds 对齐 (9 DID)
        final testPids = <ObdPid>[];
        for (final id in ['uds_rpm', 'uds_speed', 'uds_accel', 'uds_boost_b1',
            'uds_torque', 'uds_coolant', 'uds_fuel_hp', 'uds_lambda_b1', 'uds_kr_avg']) {
          final p = ObdPids.byId(id);
          if (p != null) testPids.add(p);
        }

        if (testPids.isEmpty) {
          _log('SYS', '  ⚠ 参数查找失败, 跳过');
        } else {
          final multiTimes = <int>[];
          int parseOkCount = 0;
          int parseFailCount = 0;
          Map<String, List<int>>? lastResult;

          for (var i = 0; i < (rounds / 2).ceil(); i++) {
            final t0 = DateTime.now();
            final result = await sendUdsMultiDid(
              testPids, timeout: 2.0, debug: i == 0,
            );
            multiTimes.add(DateTime.now().difference(t0).inMilliseconds);
            if (result != null && result.isNotEmpty) {
              parseOkCount++;
              lastResult = result;
            } else {
              parseFailCount++;
            }
          }

          final multiAvg = multiTimes.reduce((a, b) => a + b) / multiTimes.length;
          final multiMin = multiTimes.reduce((a, b) => a < b ? a : b);
          final multiMax = multiTimes.reduce((a, b) => a > b ? a : b);
          _log('SYS', '  批量查询: 平均 ${multiAvg.toStringAsFixed(0)}ms  '
              '最快 ${multiMin}ms  最慢 ${multiMax}ms');
          _log('SYS', '  → ${(1000 / multiAvg).toStringAsFixed(1)} Hz  '
              '(逐个 ${(1000 / cycleAvg).toStringAsFixed(1)} Hz)');
          _log('SYS', '  → 提升 ${(cycleAvg / multiAvg).toStringAsFixed(1)}×');
          _log('SYS', '  解析成功: $parseOkCount/${(rounds / 2).ceil()}');

          // 显示最后一次成功解析的值 (不显示原始字节)
          if (lastResult != null) {
            for (final pid in testPids) {
              final bytes = lastResult[pid.id];
              if (bytes != null) {
                final val = pid.parseRaw(bytes);
                _log('SYS', '    ${pid.shortName.padRight(8)} '
                    '${val?.toStringAsFixed(pid.decimals) ?? "ERR"} ${pid.unit}');
              } else {
                _log('SYS', '    ${pid.shortName.padRight(8)} ❌ 未解析');
              }
            }
          }
        }
      } else {
        _log('SYS', '  ❌ ECU 不支持批量查询');
        _log('SYS', '    → 可减少查询参数数量提升频率');
      }

    }

    // ── 测试 5.5: ★ SID 0x2C 动态组合 DID (20 Hz 核心) ──
    if (commMode == CommMode.uds) {
      _log('SYS', '');
      _log('SYS', '▶ 阶段6: ★ 动态组合查询 (核心优化)');
      _log('SYS', '  传输通路: ${_stpxAvailable ? "芯片原生高速通道" : "兼容通道"}');

      // 清除旧定义
      final clearOk = await clearDynamicDid(_ecuTx, _ecuRx, dynamicDidTarget);
      _log('SYS', '  清除旧定义: ${clearOk ? "✅" : "⚠ 继续"}');

      // 验证源参数可读性 + 确认响应长度
      final testSourcesDD = <DynamicDidSource>[];
      final testPidsDD = <ObdPid>[];
      final candidateIds = ['uds_rpm', 'uds_speed', 'uds_accel', 'uds_boost_b1',
          'uds_torque', 'uds_coolant', 'uds_fuel_hp', 'uds_lambda_b1', 'uds_kr_avg', 'uds_gear'];
      _log('SYS', '  验证源参数:');
      for (final id in candidateIds) {
        final pid = ObdPids.byId(id);
        if (pid == null || !pid.canBeDynamicDid) continue;
        final data = await sendUdsData(_ecuTx, _ecuRx, pid.udsCmd, timeout: 1.5);
        if (data != null && data.length >= 3 && data[0] == 0x62) {
          final actualLen = data.length - 3;
          if (actualLen >= pid.udsDataBytes) {
            testSourcesDD.add(DynamicDidSource.fromPid(pid));
            testPidsDD.add(pid);
            _log('SYS', '    ${pid.shortName.padRight(8)} ✅ ${pid.udsDataBytes}B (ECU返${actualLen}B)');
          } else {
            _log('SYS', '    ${pid.shortName.padRight(8)} ⚠ 数据不足 (需要${pid.udsDataBytes}, 实际$actualLen)');
          }
        } else {
          _log('SYS', '    ${pid.shortName.padRight(8)} ❌ 不可读');
        }
      }

      if (testSourcesDD.isEmpty) {
        _log('SYS', '  ❌ 无可用源参数, 跳过');
      } else {
        // 定义动态组合查询
        final totalBytes = testSourcesDD.fold<int>(0, (s, e) => s + e.size);
        _log('SYS', '  定义组合: ${testSourcesDD.length} 个参数, $totalBytes 字节');
        final defineOk = await sendUdsDynamicDefine(
            _ecuTx, _ecuRx, dynamicDidTarget, testSourcesDD);

        if (!defineOk) {
          _log('SYS', '  ❌ ECU 不支持动态组合查询');
        } else {
          _log('SYS', '  ✅ 定义成功! 轮询测试:');
          final ddTimes = <int>[];
          int ddParseOk = 0;
          for (var i = 0; i < rounds; i++) {
            final t = DateTime.now();
            final payload = await readDynamicDid(dynamicDidTarget, timeout: 1.0);
            ddTimes.add(DateTime.now().difference(t).inMilliseconds);
            if (payload != null && payload.length >= totalBytes) {
              ddParseOk++;
              if (i == 0) {
                int off = 0;
                for (var j = 0; j < testPidsDD.length; j++) {
                  final pid = testPidsDD[j];
                  final sz = testSourcesDD[j].size;
                  if (off + sz <= payload.length) {
                    final bytes = payload.sublist(off, off + sz);
                    final val = pid.parseRaw(bytes);
                    _log('SYS', '    ${pid.shortName.padRight(8)} '
                        '${val?.toStringAsFixed(pid.decimals) ?? "ERR"} ${pid.unit}');
                  }
                  off += sz;
                }
              }
            }
          }
          final ddAvg = ddTimes.reduce((a, b) => a + b) / ddTimes.length;
          final ddMin = ddTimes.reduce((a, b) => a < b ? a : b);
          final ddMax = ddTimes.reduce((a, b) => a > b ? a : b);
          final ddMed = _median(ddTimes);
          final ddHz = 1000 / ddAvg;
          _log('SYS', '  组合查询: 平均 ${ddAvg.toStringAsFixed(0)}ms  '
              '中位 ${ddMed}ms  最快 ${ddMin}ms');
          _log('SYS', '  → ${ddHz.toStringAsFixed(1)} Hz  '
              '(成功: $ddParseOk/$rounds)');

          // ★ 推送 EVA 同步率
          diagBestHz = ddHz;
          _pushSyncRate(ddHz);

          // 清理
          await clearDynamicDid(_ecuTx, _ecuRx, dynamicDidTarget);
        }
      }
    }

    // ── 测试 5: App 解析开销 ──
    _log('SYS', '');
    _log('SYS', '▶ 阶段7: 应用解析性能');
    final t0 = DateTime.now();
    for (var i = 0; i < 10000; i++) {
      _parseUdsDataResponse('7E8 06 62 20 00 13 B0 00');
    }
    final parseMs = DateTime.now().difference(t0).inMilliseconds;
    _log('SYS', '  万次解析: ${parseMs}ms → 可忽略');

    _log('SYS', '');
    _log('SYS', '▶ 阶段8: 适配器高级功能检测');
    await _runStnProbe(rounds: rounds, btAvg: btAvg, canAvg:
        commMode == CommMode.uds ? (await _quickCanAvg(3)) : btAvg);

    // ── 汇总 ──
    _log('SYS', '');
    _log('SYS', '════════════════════════════════════');
    _log('SYS', '  诊断结论');
    _log('SYS', '════════════════════════════════════');
    _log('SYS', '  蓝牙基准:   ~${btAvg.toStringAsFixed(0)}ms/次');
    if (btAvg > 50) {
      _log('SYS', '  ⚠ 蓝牙延迟偏高 (>50ms)');
      _log('SYS', '    → ${linkMode == BtLinkMode.ble ? "低功耗蓝牙连接间隔过大" : "经典蓝牙传输波动"}');
    }
    if (linkMode == BtLinkMode.ble && _transport is BleTransport) {
      final ble = _transport as BleTransport;
      _log('SYS', '  数据包大小:  ${ble.negotiatedMtu}');
    }
    if (commMode == CommMode.uds) {
      _log('SYS', '  建议最大参数数: ${(900 / btAvg).floor()} (目标 >3Hz)');
      _log('SYS', '  批量查询:   ${diagMultiOk ? "✅ ${_multiDidMax >= 99 ? '全批量' : '分批(×$_multiDidMax)'}" : "❌ 不支持"}');
      _log('SYS', '  高速通道:   ${_stpxAvailable ? "✅ 可用" : "❌"}');
      _log('SYS', '  硬件组包:   ${_stcsegrEnabled ? "✅ 已启用" : "❌ 软件模式"}');
      _log('SYS', '  动态组合:   (见阶段6)');
    }
    _log('SYS', '  应用解析:   可忽略');
    _log('SYS', '════════════════════════════════════');

    // ★ 兜底: 如果 DynDID 没能推送同步率, 使用 HUD 循环 Hz
    if (diagBestHz > 0) {
      _pushSyncRate(diagBestHz);
    }

    // ★ 恢复心跳
    if (wasHbRunning) {
      _log('SYS', '▶ 恢复心跳');
      startHeartbeat();
    }
    _log('SYS', '');
  }

  // ════════════════════════════════════════════════════════════════
  // ★ 5 分钟耐久测试 — 模拟真实 HUD 轮询, 自动诊断采样率下降
  // ════════════════════════════════════════════════════════════════

  bool _enduranceRunning = false;
  bool get enduranceRunning => _enduranceRunning;

  /// 停止耐久测试
  void stopEndurance() => _enduranceRunning = false;

  /// 5 分钟连续轮询, 每 10 秒汇报 Hz, 降速时自动内联诊断
  Future<void> runEnduranceTest({int durationSec = 300}) async {
    if (!isConnected || commMode != CommMode.uds) {
      _log('ERR', '需要 UDS 模式连接'); return;
    }
    if (_enduranceRunning) return;
    _enduranceRunning = true;

    // ── 暂停心跳 ──
    final wasHb = hbRunning;
    if (hbRunning && !_stnAvailable) {
      stopHeartbeat();
      _log('SYS', '⏸ Timer 心跳暂停');
      await Future.delayed(const Duration(milliseconds: 200));
    }

    _log('SYS', '');
    _log('SYS', '═══════════════════════════════════════');
    _log('SYS', '  ★ 耐久測試 — ${durationSec ~/ 60} 分鐘連続輪詢');
    _log('SYS', '  链路: ${linkMode == BtLinkMode.ble ? "BLE" : "SPP"}');
    _log('SYS', '  目的: 検出長時間運転での採樣率低下');
    _log('SYS', '═══════════════════════════════════════');

    // ── Phase 1: 构建 Dynamic DID (与实际 HUD 一致) ──
    _log('SYS', '');
    _log('SYS', '▶ Phase 1: 動態 DID 構築');

    await ensureSession(_ecuTx, _ecuRx);

    final candidateIds = ['uds_rpm', 'uds_speed', 'uds_accel', 'uds_boost_b1',
        'uds_torque', 'uds_coolant', 'uds_fuel_hp', 'uds_lambda_b1', 'uds_kr_avg', 'uds_gear'];
    final testPids = <ObdPid>[];
    final testSources = <DynamicDidSource>[];
    final excludedPids = <ObdPid>[];

    // 清除旧定义
    await clearDynamicDid(_ecuTx, _ecuRx, dynamicDidTarget);

    for (final id in candidateIds) {
      final pid = ObdPids.byId(id);
      if (pid == null) continue;
      if (!pid.canBeDynamicDid) { excludedPids.add(pid); continue; }
      final data = await sendUdsData(_ecuTx, _ecuRx, pid.udsCmd, timeout: 1.5);
      if (data != null && data.length >= 3 && data[0] == 0x62) {
        final actualLen = data.length - 3;
        if (actualLen >= pid.udsDataBytes) {
          testSources.add(DynamicDidSource.fromPid(pid));
          testPids.add(pid);
          _log('SYS', '  ${pid.shortName.padRight(8)} ✅ ${pid.udsDataBytes}B (ECU返${actualLen}B)');
        } else {
          excludedPids.add(pid);
          _log('SYS', '  ${pid.shortName.padRight(8)} ⚠ 數據不足 (需要${pid.udsDataBytes}, 實際$actualLen) → 補充輪詢');
        }
      } else {
        excludedPids.add(pid);
        _log('SYS', '  ${pid.shortName.padRight(8)} ❌ 不可讀 → 補充輪詢');
      }
    }

    bool dynDidOk = false;
    int totalBytes = 0;
    List<_EndSlice> slices = [];

    if (testSources.isNotEmpty) {
      totalBytes = testSources.fold<int>(0, (s, e) => s + e.size);
      final ok = await sendUdsDynamicDefine(_ecuTx, _ecuRx, dynamicDidTarget, testSources);
      if (ok) {
        final verify = await readDynamicDid(dynamicDidTarget, timeout: 1.0);
        if (verify != null && verify.length >= totalBytes) {
          dynDidOk = true;
          int off = 0;
          for (int i = 0; i < testPids.length; i++) {
            slices.add(_EndSlice(testPids[i], off, testSources[i].size));
            off += testSources[i].size;
          }
          _log('SYS', '  ✅ F300 定義成功: ${testPids.length} 參數, $totalBytes B');
        } else {
          _log('SYS', '  ⚠ F300 驗證失敗, 降級為逐個讀取');
        }
      } else {
        _log('SYS', '  ⚠ 動態 DID 不支持, 降級');
      }
    }

    if (!dynDidOk) {
      _log('SYS', '  降級: 逐個 DID 輪詢模式');
      // 全部作为 excluded 处理 (candidateIds 已包含 gear)
      excludedPids.clear();
      for (final id in candidateIds) {
        final p = ObdPids.byId(id);
        if (p != null) excludedPids.add(p);
      }
    }

    _log('SYS', '  補充輪詢: ${excludedPids.length} 個 (每3週期)');
    for (final p in excludedPids) {
      _log('SYS', '    ${p.shortName}');
    }

    // ── Phase 2: 基準測定 (先跑 30 cycle 取初始 Hz) ──
    _log('SYS', '');
    _log('SYS', '▶ Phase 2: 基準測定 (30 cycle)');

    final baselineTimes = <int>[];
    for (int i = 0; i < 30 && _enduranceRunning; i++) {
      final t0 = DateTime.now();
      if (dynDidOk) {
        await readDynamicDid(dynamicDidTarget, timeout: 0.5);
      } else {
        await raw('22 20 00', timeout: 0.8, silent: true);
      }
      baselineTimes.add(DateTime.now().difference(t0).inMilliseconds);
    }
    if (baselineTimes.isEmpty || !_enduranceRunning) {
      _log('ERR', '基準測定失敗'); _cleanup(); return;
    }
    final baselineAvg = baselineTimes.reduce((a, b) => a + b) / baselineTimes.length;
    final baselineHz = 1000.0 / baselineAvg;
    _log('SYS', '  基準: ${baselineAvg.toStringAsFixed(1)}ms/cycle → ${baselineHz.toStringAsFixed(1)} Hz');
    _pushSyncRate(baselineHz);

    // ── Phase 3: 5 分鐘連続輪詢 ──
    _log('SYS', '');
    _log('SYS', '▶ Phase 3: 耐久輪詢開始');
    _log('SYS', '  [秒数]  Hz   avg(ms) med  max  | 備考');
    _log('SYS', '  ─────────────────────────────────────');

    final globalStart = DateTime.now();
    int cycle = 0;
    int testerPresentCounter = 0;

    // 10 秒窗口统计
    int windowCycles = 0;
    int windowStartMs = 0;
    final windowLatencies = <int>[];

    // 全局统计
    final hzTimeline = <_HzSample>[];
    int totalDynDidFails = 0;
    int totalSupplementCycles = 0;
    int inlineDiagCount = 0;
    double peakHz = 0;
    double minHz = 999;

    // 缓存 STPX 命令 — 使用 profile 动态 DID 地址和超时
    final dynT = _profile?.dynDidReadTimeout ?? 50;
    final dynHex = dynamicDidTarget.toRadixString(16).padLeft(4, '0').toUpperCase();
    final dynDidCmd = Uint8List.fromList(
      'STPX H:$_ecuTx, D:22$dynHex, T:$dynT, R:1\r'.codeUnits);

    while (_enduranceRunning && isConnected) {
      final elapsed = DateTime.now().difference(globalStart);
      if (elapsed.inSeconds >= durationSec) break;

      final cycleT0 = DateTime.now();
      final cycleStartMs = elapsed.inMilliseconds;

      // 初始化窗口
      if (windowStartMs == 0) windowStartMs = cycleStartMs;

      // ── 主轮询 ──
      bool mainOk = false;
      if (dynDidOk) {
        // 内联 readDynamicDid (热路径)
        final payload = await _busLock.run(() async {
          await setHeader(_ecuTx, _ecuRx);
          _rxBuf.clear();
          _rxGotPrompt = false;
          _rxCompleter = Completer<String>();
          await _transport!.write(dynDidCmd);
          return _rxCompleter!.future.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => _rxBuf.toString(),
          );
        });
        // 简单验证
        final cleaned = payload.replaceAll('\r', '\n')
            .split('\n').map((l) => l.trim().replaceAll('>', '').trim())
            .where((l) => l.isNotEmpty).join('\n').trim();
        final data = _parseUdsDataResponse(cleaned);
        if (data != null && data.length >= totalBytes + 3 && data[0] == 0x62) {
          mainOk = true;
        } else {
          totalDynDidFails++;
        }
      } else {
        // 逐个读 (降级模式下只读 RPM 做基准)
        final resp = await raw('22 20 00', timeout: 0.8, silent: true);
        mainOk = resp.isNotEmpty && !resp.contains('ERROR');
      }

      // ── 补充轮询 (每 3 cycle) ──
      int supplementMs = 0;
      if (excludedPids.isNotEmpty && cycle % 3 == 0) {
        totalSupplementCycles++;
        final supT0 = DateTime.now();
        for (final pid in excludedPids) {
          if (!_enduranceRunning) break;
          final cmd = pid.udsCmd;
          if (cmd.isEmpty) continue;
          await sendUdsData(pid.udsEcuTx, pid.udsEcuRx, cmd, timeout: 0.8);
        }
        supplementMs = DateTime.now().difference(supT0).inMilliseconds;
      }

      // ── TesterPresent (非 STN) ──
      if (!_stnAvailable) {
        testerPresentCounter++;
        if (testerPresentCounter >= 40) {
          testerPresentCounter = 0;
          await sendUdsData(_ecuTx, _ecuRx, '3E00', timeout: 0.5);
        }
      }

      final cycleMs = DateTime.now().difference(cycleT0).inMilliseconds;
      windowCycles++;
      windowLatencies.add(cycleMs);

      // ── 10 秒窗口汇报 ──
      final windowElapsed = cycleStartMs - windowStartMs;
      if (windowElapsed >= 10000) {
        final wHz = windowCycles * 1000.0 / windowElapsed;
        final wAvg = windowLatencies.reduce((a, b) => a + b) / windowLatencies.length;
        final wSorted = List<int>.from(windowLatencies)..sort();
        final wMed = wSorted[wSorted.length ~/ 2];
        final wMax = wSorted.last;
        final wP95 = wSorted[((wSorted.length - 1) * 0.95).round()];
        final sec = elapsed.inSeconds;

        if (wHz > peakHz) peakHz = wHz;
        if (wHz < minHz) minHz = wHz;
        hzTimeline.add(_HzSample(sec, wHz, wAvg, wMax));
        _pushSyncRate(wHz);

        // 判定是否降速
        final ratio = wHz / baselineHz;
        String note = '';
        if (ratio < 0.5) {
          note = '⚠⚠ 重度劣化 ${(ratio * 100).toStringAsFixed(0)}%';
        } else if (ratio < 0.7) {
          note = '⚠ 劣化 ${(ratio * 100).toStringAsFixed(0)}%';
        } else if (ratio < 0.85) {
          note = '↓ 微劣化';
        }

        // 补充轮询贡献
        final supCyclesInWindow = windowLatencies.where((t) => t > baselineAvg * 1.8).length;
        if (supCyclesInWindow > 0 && note.isEmpty) {
          note = '($supCyclesInWindow slow)';
        }

        _log('SYS', '  [${sec.toString().padLeft(3)}s] '
            '${wHz.toStringAsFixed(1).padLeft(5)} Hz  '
            '${wAvg.toStringAsFixed(0).padLeft(3)}ms '
            '${wMed.toString().padLeft(3)}  '
            '${wMax.toString().padLeft(4)}  | $note');

        // ── 内联诊断: Hz 降到基準的 70% 以下 ──
        if (ratio < 0.7 && inlineDiagCount < 3) {
          inlineDiagCount++;
          _log('SYS', '');
          _log('SYS', '  ┌─ 劣化内联診断 #$inlineDiagCount ─────────');

          // 1) BT 基准 (5 轮)
          final btTimes = <int>[];
          for (int i = 0; i < 5 && _enduranceRunning; i++) {
            final t = DateTime.now();
            await raw('AT I', silent: true);
            btTimes.add(DateTime.now().difference(t).inMilliseconds);
          }
          final btAvg = btTimes.isEmpty ? 0.0 :
              btTimes.reduce((a, b) => a + b) / btTimes.length;
          _log('SYS', '  │ BT 基準: ${btAvg.toStringAsFixed(1)}ms '
              '(初期: ${(baselineAvg * 0.3).toStringAsFixed(1)}ms 推定)');

          // 2) 单 DID 延迟
          final singleTimes = <int>[];
          for (int i = 0; i < 5 && _enduranceRunning; i++) {
            final t = DateTime.now();
            await raw('22 20 00', timeout: 0.8, silent: true);
            singleTimes.add(DateTime.now().difference(t).inMilliseconds);
          }
          final singleAvg = singleTimes.isEmpty ? 0.0 :
              singleTimes.reduce((a, b) => a + b) / singleTimes.length;
          _log('SYS', '  │ 單 DID: ${singleAvg.toStringAsFixed(1)}ms');

          // 3) 补充 PID 逐个延迟
          if (excludedPids.isNotEmpty) {
            _log('SYS', '  │ 補充 PID 逐個:');
            for (final pid in excludedPids) {
              if (!_enduranceRunning) break;
              final t = DateTime.now();
              final resp = await sendUdsData(
                  pid.udsEcuTx, pid.udsEcuRx, pid.udsCmd, timeout: 0.8);
              final ms = DateTime.now().difference(t).inMilliseconds;
              final ok = resp != null && resp.isNotEmpty;
              _log('SYS', '  │   ${pid.shortName.padRight(8)} ${ms}ms ${ok ? "" : "❌ TIMEOUT"}');
            }
          }

          // 4) DynDID 延迟
          if (dynDidOk) {
            final ddTimes = <int>[];
            for (int i = 0; i < 5 && _enduranceRunning; i++) {
              final t = DateTime.now();
              await readDynamicDid(dynamicDidTarget, timeout: 0.5);
              ddTimes.add(DateTime.now().difference(t).inMilliseconds);
            }
            final ddAvg = ddTimes.isEmpty ? 0.0 :
                ddTimes.reduce((a, b) => a + b) / ddTimes.length;
            _log('SYS', '  │ DynDID: ${ddAvg.toStringAsFixed(1)}ms '
                '(初期: ${baselineAvg.toStringAsFixed(1)}ms)');
          }

          // 判定
          if (btAvg > baselineAvg * 0.5) {
            _log('SYS', '  │ ★ 結論: BT 層劣化 (Sniff Mode / 干渉?)');
          } else if (excludedPids.isNotEmpty) {
            _log('SYS', '  │ ★ 結論: 補充輪詢タイムアウト疑い');
          } else {
            _log('SYS', '  │ ★ 結論: ECU 応答遅延 / CAN 競合');
          }
          _log('SYS', '  └──────────────────────────');
          _log('SYS', '');
        }

        // 重置窗口
        windowCycles = 0;
        windowStartMs = cycleStartMs;
        windowLatencies.clear();
      }

      cycle++;
      await Future.delayed(Duration.zero);
    }

    // ── Phase 4: 汇总报告 ──
    final totalSec = DateTime.now().difference(globalStart).inSeconds;
    _log('SYS', '');
    _log('SYS', '═══════════════════════════════════════');
    _log('SYS', '  耐久測試完了 — ${totalSec}s / $cycle cycles');
    _log('SYS', '═══════════════════════════════════════');
    _log('SYS', '  基準 Hz:     ${baselineHz.toStringAsFixed(1)}');
    _log('SYS', '  最高 Hz:     ${peakHz.toStringAsFixed(1)}');
    _log('SYS', '  最低 Hz:     ${minHz > 900 ? "--" : minHz.toStringAsFixed(1)}');
    _log('SYS', '  DynDID 失敗: $totalDynDidFails');
    _log('SYS', '  補充輪詢回:  $totalSupplementCycles');
    _log('SYS', '  内部診断:    $inlineDiagCount 回');

    // Hz タイムライン
    if (hzTimeline.isNotEmpty) {
      _log('SYS', '');
      _log('SYS', '  ── Hz タイムライン ──');
      for (final s in hzTimeline) {
        final bar = '█' * (s.hz / baselineHz * 20).round().clamp(0, 30);
        final ratio = (s.hz / baselineHz * 100).toStringAsFixed(0);
        _log('SYS', '  ${s.sec.toString().padLeft(3)}s  '
            '${s.hz.toStringAsFixed(1).padLeft(5)} Hz  '
            '${ratio.padLeft(3)}%  $bar');
      }

      // 劣化検出
      final firstDrop = hzTimeline.indexWhere((s) => s.hz < baselineHz * 0.7);
      if (firstDrop >= 0) {
        final dropSec = hzTimeline[firstDrop].sec;
        _log('SYS', '');
        _log('SYS', '  ★ 初回劣化検出: ${dropSec}s 目 (${(dropSec / 60).toStringAsFixed(1)}分)');
        // 分析 max latency 趋势
        final earlySlice = hzTimeline.take(3).toList();
        final lateSlice = hzTimeline.skip(firstDrop).take(3).toList();
        if (earlySlice.isNotEmpty && lateSlice.isNotEmpty) {
          final earlyMax = earlySlice.map((s) => s.maxMs).reduce((a, b) => a > b ? a : b);
          final lateMax = lateSlice.map((s) => s.maxMs).reduce((a, b) => a > b ? a : b);
          if (lateMax > earlyMax * 2) {
            _log('SYS', '  ★ 最大遅延: ${earlyMax}ms → ${lateMax}ms (${(lateMax / earlyMax).toStringAsFixed(1)}x)');
            _log('SYS', '  ★ BT 層劣化の可能性が高い');
          }
        }
      } else {
        _log('SYS', '');
        _log('SYS', '  ✅ 劣化なし — 全期間安定');
      }
    }

    _log('SYS', '═══════════════════════════════════════');

    // cleanup
    if (dynDidOk) {
      await clearDynamicDid(_ecuTx, _ecuRx, dynamicDidTarget);
    }
    if (wasHb) startHeartbeat();
    _enduranceRunning = false;
  }

  void _cleanup() {
    clearDynamicDid(_ecuTx, _ecuRx, dynamicDidTarget).catchError((_) {});
    _enduranceRunning = false;
  }
  static int _median(List<int> vals) {
    final s = List<int>.from(vals)..sort();
    return s[s.length ~/ 2];
  }
  static int _percentile(List<int> vals, int p) {
    final s = List<int>.from(vals)..sort();
    final idx = ((p / 100) * (s.length - 1)).round().clamp(0, s.length - 1);
    return s[idx];
  }

  /// 快速 CAN 均值 (N 轮 RPM)
  Future<double> _quickCanAvg(int n) async {
    final times = <int>[];
    for (var i = 0; i < n; i++) {
      final t = DateTime.now();
      await raw('22 20 00', timeout: 1.0, silent: true);
      times.add(DateTime.now().difference(t).inMilliseconds);
    }
    return times.isEmpty ? 50.0 : times.reduce((a, b) => a + b) / times.length;
  }

  // ══════════════════════════════════════════════════════════════
  // ★ STN 扩展指令探测 (OBDLink MX+ / CX 芯片原生能力)
  // ══════════════════════════════════════════════════════════════
  //
  //  STN2120 芯片除 ELM327 兼容层 (AT 命令) 外, 有独立的 ST 指令集:
  //    STI      — 芯片型号
  //    STDI     — 设备详情 (固件版本, 硬件版本)
  //    STPX     — Protocol Execute (绕过 ELM327 层直接 CAN)
  //    STMA     — Monitor All (被动监听)
  //    STFCP    — Flow Control Parameters
  //    STCFCPA  — CAN FC Auto
  //    STPTO    — Protocol Timeout (ms 级精度)
  //
  //  STPX 关键: 省 ASCII 编解码 + 提示符等待 → 每次省 10-15ms
  //
  Future<void> _runStnProbe({
    required int rounds,
    required double btAvg,
    required double canAvg,
  }) async {

    // ── 芯片识别 ──
    final stnId = (await raw('STI', timeout: 1.0, silent: true)).trim();
    if (stnId.isEmpty || stnId.toUpperCase().contains('?') ||
        stnId.toUpperCase().contains('ERROR')) {
      _log('SYS', '  ❌ 高级功能不可用 (基础适配器)');
      _log('SYS', '  → 仅兼容模式');
      return;
    }
    _log('SYS', '  芯片: $stnId');

    final stnDi = (await raw('STDI', timeout: 1.0, silent: true)).trim();
    if (stnDi.isNotEmpty) _log('SYS', '  固件: $stnDi');

    // ── 高速通道测试 ──
    _log('SYS', '');
    _log('SYS', '  ── 高速直通通道 ──');
    final stpxResp = (await raw('STPX H:7E0, D:22 20 00',
        timeout: 2.0, silent: true)).trim();
    if (stpxResp.isEmpty || stpxResp.contains('?') || stpxResp.contains('ERROR')) {
      _log('SYS', '  ❌ 高速通道不可用');
    } else {
      _log('SYS', '  ✅ 高速通道正常');

      // ── 单参数延迟 ──
      final stpxTimes = <int>[];
      for (var i = 0; i < rounds; i++) {
        final t = DateTime.now();
        await raw('STPX H:7E0, D:22 20 00', timeout: 1.5, silent: true);
        stpxTimes.add(DateTime.now().difference(t).inMilliseconds);
      }
      final stpxAvg = stpxTimes.reduce((a, b) => a + b) / stpxTimes.length;
      final stpxMin = stpxTimes.reduce((a, b) => a < b ? a : b);
      final stpxMax = stpxTimes.reduce((a, b) => a > b ? a : b);
      final stpxMed = _median(stpxTimes);
      _log('SYS', '  单参数: 平均 ${stpxAvg.toStringAsFixed(0)}ms  '
          '中位 ${stpxMed}ms  最快 ${stpxMin}ms');
      _log('SYS', '  vs 兼容通道: ${canAvg.toStringAsFixed(0)}ms  '
          '→ 快 ${(canAvg - stpxAvg).toStringAsFixed(0)}ms/参数');

      // ── 双参数测试 ──
      final stpx2 = (await raw('STPX H:7E0, D:22 20 00 20 11',
          timeout: 2.0, silent: true)).trim();
      if (stpx2.isNotEmpty && !stpx2.contains('?')) {
        _log('SYS', '  双参数合并查询: ✅');
      }

      // ── 全参数批量查询测试 ──
      // 9参数合并查询 (与仪表盘参数对齐)
      const stpx9Cmd = 'STPX H:7E0, D:22 20 00 50 21 20 29 20 77 60 00 20 11 20 71 61 31 60 40';
      final stpx9 = (await raw(stpx9Cmd, timeout: 3.0, silent: true)).trim();
      final stpx9IsNrc = stpx9.toUpperCase().contains('7F 22');
      final stpx9Ok = stpx9.isNotEmpty && !stpx9.contains('?') && !stpx9IsNrc;
      if (stpx9Ok) {
        _log('SYS', '  ✅ 全参数批量查询可用');

        // 延迟测试
        final stpx9Times = <int>[];
        for (var i = 0; i < (rounds / 2).ceil(); i++) {
          final t = DateTime.now();
          await raw(stpx9Cmd, timeout: 3.0, silent: true);
          stpx9Times.add(DateTime.now().difference(t).inMilliseconds);
        }
        final s9Avg = stpx9Times.reduce((a, b) => a + b) / stpx9Times.length;
        final s9Min = stpx9Times.reduce((a, b) => a < b ? a : b);
        final s9Max = stpx9Times.reduce((a, b) => a > b ? a : b);
        _log('SYS', '  全参数高速: 平均 ${s9Avg.toStringAsFixed(0)}ms  '
            '最快 ${s9Min}ms');
        _log('SYS', '  → ${(1000 / s9Avg).toStringAsFixed(1)} Hz');
      } else if (stpx9IsNrc) {
        _log('SYS', '  ❌ ECU 拒绝全参数合并 (数量限制)');
        _log('SYS', '    → 正常: 使用动态组合查询代替');
      } else {
        _log('SYS', '  ❌ 全参数批量: ${stpx9.isEmpty ? "无响应" : "异常"}');
      }

      // ── 高速通道仪表盘模拟 ──
      _log('SYS', '');
      _log('SYS', '  ── 高速通道逐参数模拟 ──');
      final stpxDids = ['22 20 00', '22 50 21', '22 20 29', '22 20 77',
          '22 60 00', '22 20 11', '22 20 71', '22 61 31', '22 60 40'];
      final stpxCycleTimes = <int>[];
      for (var c = 0; c < (rounds / 2).ceil(); c++) {
        final ct = DateTime.now();
        for (final did in stpxDids) {
          await raw('STPX H:7E0, D:$did', timeout: 1.5, silent: true);
        }
        stpxCycleTimes.add(DateTime.now().difference(ct).inMilliseconds);
      }
      final scAvg = stpxCycleTimes.reduce((a, b) => a + b) / stpxCycleTimes.length;
      _log('SYS', '  9参数逐个: 平均 ${scAvg.toStringAsFixed(0)}ms  '
          '→ ${(1000 / scAvg).toStringAsFixed(1)} Hz');
    }

    // ── 其他高级功能探测 ──
    // ★ 用 set 命令探测 (裸查询在 STBCOF 1 模式下可能不返回 > 提示符)
    _log('SYS', '');
    _log('SYS', '  ── 其他高级功能 ──');
    final stProbes = <String, String>{
      '精确超时控制':   'STPTO 70',                    // 设回 init 值 (STPTO 70), 期望 OK
      '硬件流控':      'STCFCPA $_ecuTx, $_ecuRx',    // ★ 重注册 FC 地址对 (非开关!)
      '流控参数':      'STFCP',
      '总线监听模式':   'STCMM 1',
    };
    for (final e in stProbes.entries) {
      final resp = (await raw(e.value, timeout: 1.5, silent: true)).trim();
      final ok = resp.isNotEmpty && !resp.contains('?') && !resp.contains('ERROR');
      _log('SYS', '  ${e.key.padRight(12)} ${ok ? "✅" : "❌"}'
          '${ok ? "" : "  [$resp]"}');
    }
    // 恢复总线监听关闭
    await raw('STCMM 0', timeout: 1.0, silent: true);

    // ── 汇总 ──
    _log('SYS', '');
    _log('SYS', '  ── 适配器能力总结 ──');
    _log('SYS', '  芯片: $stnId');
    _log('SYS', '  高速通道: ${stpxResp.contains('?') ? "❌" : "✅"}');
    _log('SYS', '  硬件组包: ${_stcsegrEnabled ? "✅ 已启用" : "❌ 软件模式"}');
    _log('SYS', '  → 高速通道可省 ~10-15ms/参数');
  }

}

// ════════════════════════════════════════════════════════════════
// 耐久测试辅助类
// ════════════════════════════════════════════════════════════════

class _EndSlice {
  final ObdPid pid;
  final int offset;
  final int size;
  const _EndSlice(this.pid, this.offset, this.size);
}

class _HzSample {
  final int sec;
  final double hz;
  final double avgMs;
  final int maxMs;
  const _HzSample(this.sec, this.hz, this.avgMs, this.maxMs);
}