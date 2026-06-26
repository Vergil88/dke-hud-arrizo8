import 'package:flutter/material.dart';
import '../models/hud_channel_config.dart';

// ════════════════════════════════════════════════════════════════
// hud_skin.dart — HUD 皮肤插件系统
// ════════════════════════════════════════════════════════════════

/// 单个通道的显示数据 (传给皮肤层)
class ChannelDisplay {
  final String label;
  final String jpLabel;
  final String pidId;
  final String unit;
  final double value;
  final double gaugeMax;
  final double caution;
  final double danger;
  final bool isCaution;
  final bool isDanger;
  // ★ 警报配置透传 (皮肤层需要读取)
  final AlertStyle alertStyle;
  final String alertTitleJp;
  final String alertTitleEn;

  const ChannelDisplay({
    required this.label,
    this.jpLabel = '',
    required this.pidId,
    this.unit = '',
    this.value = 0,
    this.gaugeMax = 100,
    this.caution = 0,
    this.danger = 0,
    this.isCaution = false,
    this.isDanger = false,
    this.alertStyle = AlertStyle.none,
    this.alertTitleJp = '',
    this.alertTitleEn = '',
  });
}

/// ★ 活跃警报信息 (编排器传给皮肤)
class ActiveAlert {
  final HudSlot slot;
  final AlertStyle style;
  final String titleJp;
  final String titleEn;
  final double value;     // 触发时的参数值 (叠层显示用)
  final String unit;

  const ActiveAlert({
    required this.slot,
    required this.style,
    this.titleJp = '',
    this.titleEn = '',
    this.value = 0,
    this.unit = '',
  });

  /// 警报优先级 (数值越大越优先显示)
  int get priority => switch (style) {
    AlertStyle.emergency    => 3,
    AlertStyle.fuelCritical => 3,
    AlertStyle.afrAnomaly   => 3,
    AlertStyle.overboost    => 2,
    AlertStyle.overheat     => 2,
    AlertStyle.generic      => 1,
    AlertStyle.none         => 0,
  };

  /// ★ 有效优先级 (含衰减): 显示超过 decayTicks 后降级
  /// shownTicks: 该警报累计显示的 tick 数
  /// decayAfter: 多少 tick 后开始衰减 (默认 300 = 10s @30fps)
  int effectivePriority(int shownTicks, {int decayAfter = 300}) {
    if (shownTicks <= decayAfter) return priority;
    return (priority - 1).clamp(0, 99);
  }
}

/// ── 数据包: 编排器传给皮肤的全部数据 ──
class HudData {
  final Map<String, double> values;
  final bool flashOn;
  final int tick;
  final double boostPeakHold;
  final int boostPeakTick;
  // ★ 升档警报 (独立于通道体系)
  final bool wShift;
  // ★ 全力全開警报 (独立于通道体系)
  final bool wFullThrottle;
  // ★ 全力全開持続 tick 数 (0=非活性, >0=活性化からの経過 tick)
  final int fullThrottleTicks;
  // ★ 退出動画 (0=非活性, 1-20=退出アニメ進行中)
  final int ftExitTick;
  // ★ 解除時の fullThrottleTicks (退出アニメの開始サイズ計算用)
  final int ftPeakTick;
  // ★ 通道警报 (数据驱动, 替代旧的 wCool/wKnock)
  final List<ActiveAlert> activeAlerts;
  // ★ 多重警報系統
  final int displayAlertIndex;       // 当前显示的警报索引 (轮播用)
  final bool multiCrisis;            // 3+警报 → 多重警報発令
  final List<int> alertShownTicks;   // 每个警报的累计显示 tick 数 (衰减用)

  final bool slipping;
  final int gearChangeKey;
  final bool obdGearMode;   // ★ true = DID 0x5020 实际档位模式
  final double peakBoost, peakTorque, peakLatG, peakLonG;
  final double rpmMax;
  final double shiftRpm;
  final List<ChannelDisplay> channelDisplays;

  const HudData({
    required this.values,
    required this.flashOn,
    required this.tick,
    required this.boostPeakHold,
    required this.boostPeakTick,
    required this.wShift,
    this.wFullThrottle = false,
    this.fullThrottleTicks = 0,
    this.ftExitTick = 0,
    this.ftPeakTick = 0,
    this.activeAlerts = const [],
    this.displayAlertIndex = 0,
    this.multiCrisis = false,
    this.alertShownTicks = const [],
    required this.slipping,
    required this.gearChangeKey,
    this.obdGearMode = false,
    required this.peakBoost,
    required this.peakTorque,
    required this.peakLatG,
    required this.peakLonG,
    this.rpmMax = 7000,
    this.shiftRpm = 6500,
    this.channelDisplays = const [],
  });

  double v(String id) => values[id] ?? 0;

  /// ★ 便捷: 是否有任何通道警报活跃
  bool get hasAlert => activeAlerts.isNotEmpty;

  /// ★ 是否处于紧急状态 (任何警报或升档或全開)
  bool get isEmergencyMode => wShift || wFullThrottle || hasAlert;

  /// ★ 最高优先级的活跃警报 (用于决定全屏叠层)
  ActiveAlert? get topAlert {
    if (activeAlerts.isEmpty) return null;
    return activeAlerts.reduce((a, b) => a.priority >= b.priority ? a : b);
  }

  /// ★ 当前轮播显示的警报
  ActiveAlert? get displayedAlert {
    if (activeAlerts.isEmpty) return null;
    final idx = displayAlertIndex.clamp(0, activeAlerts.length - 1);
    return activeAlerts[idx];
  }

  /// ★ 当前显示警报的累计 tick (用于皮肤层判断衰减进度)
  int get displayedAlertShownTicks {
    if (alertShownTicks.isEmpty || activeAlerts.isEmpty) return 0;
    final idx = displayAlertIndex.clamp(0, alertShownTicks.length - 1);
    return idx < alertShownTicks.length ? alertShownTicks[idx] : 0;
  }
}

/// ── 抽象基类: 所有 HUD 皮肤必须继承 ──
abstract class HudSkin extends StatelessWidget {
  final HudData d;
  const HudSkin({super.key, required this.d});
}

typedef HudSkinBuilder = HudSkin Function({Key? key, required HudData d});

class HudSkinInfo {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  final Color accent;
  final HudSkinBuilder builder;

  const HudSkinInfo({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.accent,
    required this.builder,
  });
}

class HudSkinRegistry {
  HudSkinRegistry._();
  static final _skins = <HudSkinInfo>[];

  static void register(HudSkinInfo info) {
    _skins.removeWhere((s) => s.id == info.id);
    _skins.add(info);
  }

  static List<HudSkinInfo> get all => List.unmodifiable(_skins);

  static HudSkinInfo find(String id) =>
    _skins.firstWhere((s) => s.id == id, orElse: () => _skins.first);

  static int get count => _skins.length;

  static HudSkin build(String id, {Key? key, required HudData data}) =>
    find(id).builder(key: key, d: data);
}