import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'obd_transport.dart';

/// iOS BLE 传输（封装 flutter_blue_plus，适配 OBDLink CX）
///
/// OBDLink CX BLE UART 服务:
///   Service  : FFF0
///   RX Notify: FFF1 (设备→手机, 订阅通知)
///   TX Write : FFF2 (手机→设备, 写入命令)
class BleTransport implements OBDTransport {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar; // FFF2
  BluetoothCharacteristic? _rxChar; // FFF1
  StreamSubscription? _notifySub;
  StreamSubscription? _connStateSub;
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  final _stateCtrl = StreamController<bool>.broadcast();
  bool _connected = false;
  int _mtu = 20;
  bool _canWriteNoResp = false;

  /// 获取协商后的 MTU (供外部日志)
  int get negotiatedMtu => _mtu;

  static final _serviceUuid =
      Guid("0000fff0-0000-1000-8000-00805f9b34fb");
  static final _rxCharUuid =
      Guid("0000fff1-0000-1000-8000-00805f9b34fb");
  static final _txCharUuid =
      Guid("0000fff2-0000-1000-8000-00805f9b34fb");

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get dataStream => _dataCtrl.stream;

  @override
  Stream<bool> get connectionState => _stateCtrl.stream;

  @override
  Future<void> connect(OBDDevice device) async {
    _device = device.nativeDevice as BluetoothDevice;

    // 监听底层连接状态
    _connStateSub = _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && _connected) {
        _connected = false;
        _stateCtrl.add(false);
      }
    });

    // 连接 (CX 不需要预配对, 连接后自动握手)
    await _device!.connect(timeout: const Duration(seconds: 15));

    // ★ 请求高优先级连接参数 (Android)
    //   connectionPriority.high → 连接间隔 7.5~15ms (默认 30~50ms)
    //   这是解决 841ms 尖峰的关键 — 减少 BLE interval 等待
    try {
      await _device!.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
    } catch (_) {} // iOS 不支持, 忽略

    // 请求大 MTU (Android 建议 512, CX 会协商到 247)
    try {
      _mtu = await _device!.requestMtu(512);
    } catch (_) {
      _mtu = 23; // fallback
    }

    // 发现服务 & 特征
    final services = await _device!.discoverServices();
    for (final svc in services) {
      if (svc.serviceUuid == _serviceUuid) {
        for (final ch in svc.characteristics) {
          if (ch.characteristicUuid == _rxCharUuid) {
            _rxChar = ch;
          } else if (ch.characteristicUuid == _txCharUuid) {
            _txChar = ch;
          }
        }
      }
    }

    if (_txChar == null || _rxChar == null) {
      await _device!.disconnect();
      throw Exception('未找到 OBDLink CX UART 服务 (FFF0/FFF1/FFF2)');
    }

    // 检测 FFF2 是否支持 writeWithoutResponse
    _canWriteNoResp = _txChar!.properties.writeWithoutResponse;

    // 订阅 RX 通知 — 同时触发 CX 配对流程
    await _rxChar!.setNotifyValue(true);
    _notifySub = _rxChar!.onValueReceived.listen((data) {
      _dataCtrl.add(Uint8List.fromList(data));
    });

    _connected = true;
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_txChar == null || !_connected) return;

    // ★ OBDLink CX 文档: write.withoutResponse 开销 12 字节, write.default 开销 3 字节
    //   writeWithoutResponse 省一个 BLE 往返 (~7.5-15ms), 大幅减少延迟
    //   但可用 payload 更小: MTU - 12 vs MTU - 3
    final overhead = _canWriteNoResp ? 12 : 3;
    final chunkSize = (_mtu - overhead).clamp(20, 244);

    if (data.length <= chunkSize) {
      await _txChar!.write(data.toList(), withoutResponse: _canWriteNoResp);
    } else {
      for (var i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, data.length);
        await _txChar!.write(
          data.sublist(i, end).toList(),
          withoutResponse: _canWriteNoResp,
        );
      }
    }
  }

  @override
  Future<void> disconnect() async {
    _notifySub?.cancel();
    _connStateSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _txChar = null;
    _rxChar = null;
    _connected = false;
  }

  // ═══ iOS BLE 专用静态方法 ═══

  /// BLE 扫描 — 过滤 OBDLink CX 的 FFF0 服务
  static Future<List<OBDDevice>> scanDevices({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 停止可能正在进行的扫描
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    await FlutterBluePlus.startScan(
      timeout: timeout,
      withServices: [_serviceUuid],
    );

    // 等待扫描完成
    await FlutterBluePlus.isScanning.where((s) => !s).first;

    final results = FlutterBluePlus.lastScanResults;
    return results.map((r) {
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : (r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : 'OBDLink CX');
      return OBDDevice(
        name: name,
        address: r.device.remoteId.str,
        nativeDevice: r.device,
      );
    }).toList();
  }

  static Future<bool> isBluetoothEnabled() async {
    // adapterStateNow 首次可能为 unknown, 需等待实际状态
    final state = FlutterBluePlus.adapterStateNow;
    if (state != BluetoothAdapterState.unknown) {
      return state == BluetoothAdapterState.on;
    }
    // 等待第一个非 unknown 状态 (最多 3 秒)
    try {
      final realState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
      return realState == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  /// Android BLE 可尝试 turnOn, iOS 无法编程式开启
  static Future<bool> requestEnable() async {
    try {
      await FlutterBluePlus.turnOn();
      // 等待状态变为 on (最多 5 秒)
      final state = await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false; // iOS 会抛异常, Android 用户可能拒绝
    }
  }
}
