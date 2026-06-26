import 'dart:async';
import 'dart:typed_data';

/// 跨平台蓝牙设备模型（统一 SPP 与 BLE）
class OBDDevice {
  final String name;
  final String address; // Android: MAC, iOS: UUID
  final dynamic nativeDevice; // 底层平台对象

  OBDDevice({required this.name, required this.address, this.nativeDevice});
}

/// 抽象传输层 — SPP 和 BLE 的公共接口
abstract class OBDTransport {
  bool get isConnected;

  /// 接收数据流
  Stream<Uint8List> get dataStream;

  /// 连接状态变化（false = 断开）
  Stream<bool> get connectionState;

  /// 连接设备
  Future<void> connect(OBDDevice device);

  /// 发送字节
  Future<void> write(Uint8List data);

  /// 断开并释放资源
  Future<void> disconnect();
}
