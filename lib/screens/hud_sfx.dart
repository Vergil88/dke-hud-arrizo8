// ════════════════════════════════════════════════════════════════════
// HUD 統一音効管理器
// ════════════════════════════════════════════════════════════════════
// ★ 单例, Android 专用 (.ogg)
// ★ 预置音效注册表 — 新增音效只需在 _kRegistry 添加一行
// ★ 提供 play(id) 统一入口, 支持 overlap 控制
// ════════════════════════════════════════════════════════════════════

import 'package:audioplayers/audioplayers.dart';

/// 音效元数据 (不可变)
class SfxEntry {
  final String id;          // 唯一标识, 持久化/配置引用用
  final String displayName; // UI 显示名
  final String fileName;    // assets/sfx/ 下的文件名 (不含 .ogg)

  const SfxEntry({
    required this.id,
    required this.displayName,
    required this.fileName,
  });
}

/// 警报重叠模式
enum AlertOverlapMode {
  /// 同时播放 (混音)
  simultaneous,
  /// 新警报打断当前警报
  interrupt,
}

// ════════════════════════════════════════════════════════════════════
// 预置音效注册表
// ════════════════════════════════════════════════════════════════════
// ★ 扩展: 新增音效只需在此追加一行 + 放入 assets/sfx/xxx.ogg
// ════════════════════════════════════════════════════════════════════

/// 特殊 id: 表示不播放任何音效
const kSfxNone = 'none';

const _kRegistry = <SfxEntry>[
  SfxEntry(id: 'eva_upshift', displayName: '升档警告',       fileName: 'eva_upshift'),
  SfxEntry(id: 'eva_cooling', displayName: '冷却過熱',       fileName: 'eva_cooling'),
  SfxEntry(id: 'eva_knock',   displayName: '異常検出',       fileName: 'eva_knock'),
  SfxEntry(id: 'eva_overboost', displayName: '増圧限界',     fileName: 'eva_overboost'),
  SfxEntry(id: 'eva_fullthrottle', displayName: '全力全開', fileName: 'eva_fullthrottle'),
  SfxEntry(id: 'eva_fuelpressurelow', displayName: '燃圧喪失', fileName: 'eva_fuelpressurelow'),
  SfxEntry(id: 'eva_afr',            displayName: '空燃比異常', fileName: 'eva_afr'),
  SfxEntry(id: 'eva_can1',    displayName: '連接音効',       fileName: 'eva_can1'),
  // ── 扩展示例 ──
  // SfxEntry(id: 'eva_fuel', displayName: '燃料警報', fileName: 'eva_fuel'),
];

/// 非警报类音效 (连接音等), 不参与 overlap 打断
const _kNonAlertIds = <String>{'eva_can1'};

class HudSfx {
  HudSfx._();
  static final instance = HudSfx._();

  // ── 注册表查询 ──────────────────────────────────

  /// 全部可用音效元数据
  static List<SfxEntry> get registry => List.unmodifiable(_kRegistry);

  /// 可选音效 id 列表 (含 'none', 供 UI 下拉选择)
  static List<String> get selectableIds =>
      [kSfxNone, ..._kRegistry.map((e) => e.id)];

  /// 按 id 查找, 找不到返回 null
  static SfxEntry? findById(String id) {
    if (id == kSfxNone) return null;
    for (final e in _kRegistry) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 音效显示名 (UI 用)
  static String displayNameOf(String id) {
    if (id == kSfxNone) return '无 (OFF)';
    return findById(id)?.displayName ?? id;
  }

  // ── 播放器池 ────────────────────────────────────

  final _players = <String, AudioPlayer>{};
  bool _inited = false;

  double _volume = 0.8;
  double get volume => _volume;
  set volume(double v) {
    _volume = v.clamp(0.0, 1.0);
    _applyVolume();
  }

  /// HUD 模式标志 — 切换到 alarm 音频流, 系统级增大音量
  bool _hudMode = false;
  bool get hudMode => _hudMode;

  void setHudMode(bool on) {
    if (_hudMode == on) return;
    _hudMode = on;
    // 切换 AudioContext: alarm 流在 Android 上使用闹钟音量, 通常远大于媒体音量
    final ctx = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        audioMode: AndroidAudioMode.normal,
        stayAwake: false,
        contentType: on ? AndroidContentType.music : AndroidContentType.sonification,
        usageType: on ? AndroidUsageType.alarm : AndroidUsageType.assistanceSonification,
        audioFocus: on ? AndroidAudioFocus.gain : AndroidAudioFocus.gainTransientMayDuck,
      ),
    );
    AudioPlayer.global.setAudioContext(ctx);
    _applyVolume();
  }

  void _applyVolume() {
    // HUD 模式下强制 1.0 (配合 alarm 流实现最大音量)
    final effective = _hudMode ? 1.0 : _volume;
    for (final p in _players.values) {
      try { p.setVolume(effective); } catch (_) {}
    }
  }

  AlertOverlapMode overlapMode = AlertOverlapMode.interrupt;

  // ── 生命周期 ────────────────────────────────────

  /// 预加载全部注册音效 (App/HUD 启动时调用)
  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    final ctx = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        audioMode: AndroidAudioMode.normal,
        stayAwake: false,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.assistanceSonification,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    );
    AudioPlayer.global.setAudioContext(ctx);

    await Future.wait(_kRegistry.map((e) => _load(e.id, e.fileName)));
  }

  Future<void> _load(String id, String fileName) async {
    try {
      final p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setVolume(_volume);
      await p.setSource(AssetSource('sfx/$fileName.ogg'));
      _players[id] = p;
    } catch (_) {}
  }

  void dispose() {
    for (final p in _players.values) {
      try { p.stop(); p.dispose(); } catch (_) {}
    }
    _players.clear();
    _inited = false;
    _hudMode = false;
  }

  /// 停止所有正在播放的音效 (不销毁播放器)
  void stopAll() {
    for (final p in _players.values) {
      try { p.stop(); } catch (_) {}
    }
  }

  // ── 播放 ────────────────────────────────────────

  /// ★ 统一播放入口
  void play(String id) {
    if (id == kSfxNone) return;
    final p = _players[id];
    if (p == null) return;

    // 警报类: overlap 控制
    if (!_kNonAlertIds.contains(id)) {
      if (overlapMode == AlertOverlapMode.interrupt) {
        for (final e in _players.entries) {
          if (e.key != id && !_kNonAlertIds.contains(e.key)) {
            e.value.stop().catchError((_) {});
          }
        }
      }
    }

    final effective = _hudMode ? 1.0 : _volume;
    p.setVolume(effective).catchError((_) {});
    p.seek(Duration.zero).then((_) => p.resume()).catchError((_) {});
  }

  /// 升档音效 (独立于通道体系, 直接调用)
  void playUpshift() => play('eva_upshift');

  /// 全力全開音效 (独立于通道体系, 直接调用)
  void playFullThrottle() => play('eva_fullthrottle');

  /// 连接音效
  void playCan1() => play('eva_can1');
}
