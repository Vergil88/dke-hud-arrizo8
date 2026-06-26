// ════════════════════════════════════════════════════════════════
// dke_logger.dart — 文件日志 (保存到 app 私有目录，免权限)
// ════════════════════════════════════════════════════════════════
// Android 11+ 不允许写入 /sdcard/ 公共目录。
// 使用 app 私有外部存储: /sdcard/Android/data/com.dk.eva.eva_hud_app/files/DKE/logs/
// 此路径无需 MANAGE_EXTERNAL_STORAGE 权限。

import 'dart:core';
import 'dart:io';

class DkeLogger {
  static final DkeLogger instance = DkeLogger._();
  DkeLogger._();

  IOSink? _sink;
  String _currentLogPath = '';

  /// App 私有日志目录 (免权限)
  static String get _logDir {
    // Android: /sdcard/Android/data/com.dk.eva.eva_hud_app/files/DKE/logs/
    // iOS: not supported yet
    if (Platform.isAndroid) {
      return '/sdcard/Android/data/com.dk.eva.eva_hud_app/files/DKE/logs';
    }
    return '/sdcard/DKE/logs'; // fallback
  }

  /// 开始记录到文件
  Future<void> start() async {
    try {
      final dir = Directory(_logDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final now = DateTime.now();
      final name = 'dke_${_fmt(now)}.log';
      _currentLogPath = '${dir.path}/$name';
      final file = File(_currentLogPath);
      _sink = file.openWrite(mode: FileMode.append);
      _sink!.writeln('=== DKE Log Start ${now.toIso8601String()} ===');
      // 清理旧日志 (保留最近 20 个)
      _cleanOldLogs(dir);
    } catch (e) {
      // 静默失败，避免崩溃
    }
  }

  /// 写入一行日志
  void write(String tag, String msg) {
    try {
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      _sink?.writeln('$ts [$tag] $msg');
      _sink?.flush();
    } catch (_) {}
  }

  /// 当前日志文件路径
  String get currentLogPath => _currentLogPath;

  /// 停止并关闭
  Future<void> stop() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  String _fmt(DateTime d) {
    return '${d.year}${_p(d.month)}${_p(d.day)}_${_p(d.hour)}${_p(d.minute)}${_p(d.second)}';
  }

  String _p(int n) => n.toString().padLeft(2, '0');

  void _cleanOldLogs(Directory dir) async {
    try {
      final files = await dir.list().toList();
      final logs = files
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (var i = 20; i < logs.length; i++) {
        try { await logs[i].delete(); } catch (_) {}
      }
    } catch (_) {}
  }
}
