import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'obd_transport.dart';

/// Android 经典蓝牙 SPP 传输（封装 flutter_bluetooth_serial）
class SppTransport implements OBDTransport {
  BluetoothConnection? _conn;
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  final _stateCtrl = StreamController<bool>.broadcast();
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get dataStream => _dataCtrl.stream;

  @override
  Stream<bool> get connectionState => _stateCtrl.stream;

  @override
  Future<void> connect(OBDDevice device) async {
    _conn = await BluetoothConnection.toAddress(device.address);
    _connected = true;
    _conn!.input?.listen(
      (data) => _dataCtrl.add(data),
      onDone: () {
        _connected = false;
        _stateCtrl.add(false);
      },
      onError: (_) {
        _connected = false;
        _stateCtrl.add(false);
      },
    );
  }

  @override
  Future<void> write(Uint8List data) async {
    // ★ 热路径优化: 仅加入发送队列, 不等待内核缓冲区 flush
    // allSent 等待 RFCOMM 层确认字节离开用户空间 → 5-15ms 延迟
    // 对 OBD 场景, 命令很短 (<40B), 内核缓冲区不会溢出
    // 响应的到达本身就隐含了发送已完成
    _conn?.output.add(data);
  }

  @override
  Future<void> disconnect() async {
    try {
      _conn?.finish();
      _conn?.dispose();
    } catch (_) {}
    _conn = null;
    _connected = false;
  }

  // ═══ Android 专用静态方法 ═══

  static Future<bool> isBluetoothEnabled() async =>
      await FlutterBluetoothSerial.instance.isEnabled ?? false;

  static Future<bool> requestEnable() async =>
      await FlutterBluetoothSerial.instance.requestEnable() ?? false;

  static Future<List<OBDDevice>> getDevices() async {
    final devs = await FlutterBluetoothSerial.instance.getBondedDevices();
    return devs
        .map((d) => OBDDevice(
              name: d.name ?? d.address,
              address: d.address,
              nativeDevice: d,
            ))
        .toList();
  }
}