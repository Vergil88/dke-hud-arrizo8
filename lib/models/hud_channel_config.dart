// ════════════════════════════════════════════════════════════════
// hud_channel_config.dart — HUD 数据通道 + 警报配置
// ════════════════════════════════════════════════════════════════
// 6 个数据槽位, 每个槽位自带:
//   - 数据源 (pidId) + 显示 (label/unit/gaugeMax)
//   - 阈值   (cautionHigh/Low, dangerHigh/Low, warnDirection)
//   - ★ 警报 (alertStyle, alertSfxId, alertTitle, alertBrightness)
// ════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'obd_pids.dart';
import 'vehicle_profile.dart';

// ── 6 个数据通道 ──
enum HudSlot { ch0, ch1, ch2, ch3, ch4, ch5 }

/// 警告方向
enum WarnDirection {
  high, low, both;

  static WarnDirection fromString(String s) {
    switch (s.toLowerCase()) {
      case 'low':  return WarnDirection.low;
      case 'both': return WarnDirection.both;
      default:     return WarnDirection.high;
    }
  }
}

/// 档位数据源
enum GearSource {
  /// 根据 RPM/车速/齿比 反算
  calculated,
  /// UDS DID 0x5020 实际档位
  obdPid,
}

/// ★ 全屏警报叠层视觉风格
enum AlertStyle {
  /// 不触发全屏警报 (仅仪表变色)
  none,
  /// 冷却過熱 — 热浪渐变 + 温度大字
  overheat,
  /// 非常事態 — 黑帧慢闪 + 危险条纹
  emergency,
  /// 増圧限界突破 — 能量脉冲 + 增压大字
  overboost,
  /// 燃圧喪失 — 生命線断絶 / 燃料系統崩壊
  fuelCritical,
  /// 空燃比異常 — 混合気崩壊 / AFR 逸脱 (双重条件警報)
  afrAnomaly,
  /// 通用红色闪烁 (适用于新增参数)
  generic,
}

/// 单个通道配置
class ChannelConfig {
  // ── 显示 ──
  final String label;
  final String jpLabel;
  final String pidId;
  final double gaugeMax;
  final String unitOverride;

  // ── 阈值 ──
  final double cautionHigh;
  final double dangerHigh;
  final double cautionLow;
  final double dangerLow;
  final WarnDirection warnDirection;

  // ── ★ 警报配置 ──
  final AlertStyle alertStyle;        // danger 时的全屏叠层
  final String alertSfxId;            // danger 时播放的音效 id ('none' = 静音)
  final String alertTitleJp;          // 叠层日文标题 (如 '冷却過熱')
  final String alertTitleEn;          // 叠层英文标题 (如 'OVERHEAT')
  final bool alertBoostBrightness;    // 是否触发 OLED 亮度拉满

  // ── ★ 守衛条件 (可选, 双重条件警報用) ──
  final String? alertGuardPidId;      // 第二个 PID (null = 无守衛)
  final double alertGuardMinValue;    // guardPid >= 此值时才允许触发

  const ChannelConfig({
    required this.label,
    this.jpLabel = '',
    required this.pidId,
    this.cautionHigh = 0,
    this.dangerHigh = 0,
    this.cautionLow = 0,
    this.dangerLow = 0,
    required this.gaugeMax,
    this.warnDirection = WarnDirection.high,
    this.unitOverride = '',
    this.alertStyle = AlertStyle.none,
    this.alertSfxId = 'none',
    this.alertTitleJp = '',
    this.alertTitleEn = '',
    this.alertBoostBrightness = false,
    this.alertGuardPidId,
    this.alertGuardMinValue = 0,
  });

  String get unit {
    if (unitOverride.isNotEmpty) return unitOverride;
    return ObdPids.byId(pidId)?.unit ?? '';
  }

  bool isCaution(double value) {
    switch (warnDirection) {
      case WarnDirection.high:
        return cautionHigh > 0 && value >= cautionHigh && (dangerHigh <= 0 || value < dangerHigh);
      case WarnDirection.low:
        return cautionLow > 0 && value <= cautionLow && (dangerLow <= 0 || value > dangerLow);
      case WarnDirection.both:
        return (cautionHigh > 0 && value >= cautionHigh && (dangerHigh <= 0 || value < dangerHigh)) ||
               (cautionLow > 0 && value <= cautionLow && (dangerLow <= 0 || value > dangerLow));
    }
  }

  bool isDanger(double value) {
    switch (warnDirection) {
      case WarnDirection.high:  return dangerHigh > 0 && value >= dangerHigh;
      case WarnDirection.low:   return dangerLow > 0 && value <= dangerLow;
      case WarnDirection.both:  return (dangerHigh > 0 && value >= dangerHigh) ||
                                       (dangerLow > 0 && value <= dangerLow);
    }
  }

  ChannelConfig copyWith({
    String? label, String? jpLabel, String? pidId,
    double? cautionHigh, double? dangerHigh,
    double? cautionLow, double? dangerLow,
    double? gaugeMax, WarnDirection? warnDirection, String? unitOverride,
    AlertStyle? alertStyle, String? alertSfxId,
    String? alertTitleJp, String? alertTitleEn,
    bool? alertBoostBrightness,
    String? alertGuardPidId, double? alertGuardMinValue,
  }) => ChannelConfig(
    label: label ?? this.label,
    jpLabel: jpLabel ?? this.jpLabel,
    pidId: pidId ?? this.pidId,
    cautionHigh: cautionHigh ?? this.cautionHigh,
    dangerHigh: dangerHigh ?? this.dangerHigh,
    cautionLow: cautionLow ?? this.cautionLow,
    dangerLow: dangerLow ?? this.dangerLow,
    gaugeMax: gaugeMax ?? this.gaugeMax,
    warnDirection: warnDirection ?? this.warnDirection,
    unitOverride: unitOverride ?? this.unitOverride,
    alertStyle: alertStyle ?? this.alertStyle,
    alertSfxId: alertSfxId ?? this.alertSfxId,
    alertTitleJp: alertTitleJp ?? this.alertTitleJp,
    alertTitleEn: alertTitleEn ?? this.alertTitleEn,
    alertBoostBrightness: alertBoostBrightness ?? this.alertBoostBrightness,
    alertGuardPidId: alertGuardPidId ?? this.alertGuardPidId,
    alertGuardMinValue: alertGuardMinValue ?? this.alertGuardMinValue,
  );

  Map<String, dynamic> toJson() => {
    'label': label, 'jpLabel': jpLabel, 'pidId': pidId,
    'cautionHigh': cautionHigh, 'dangerHigh': dangerHigh,
    'cautionLow': cautionLow, 'dangerLow': dangerLow,
    'gaugeMax': gaugeMax,
    'warnDirection': warnDirection.name,   // ★ 用 .name 替代 .index
    'unitOverride': unitOverride,
    'alertStyle': alertStyle.name,
    'alertSfxId': alertSfxId,
    'alertTitleJp': alertTitleJp,
    'alertTitleEn': alertTitleEn,
    'alertBoostBrightness': alertBoostBrightness,
    'alertGuardPidId': alertGuardPidId,
    'alertGuardMinValue': alertGuardMinValue,
  };

  factory ChannelConfig.fromJson(Map<String, dynamic> j) {
    // ★ warnDirection: 兼容旧版 int 和新版 string
    WarnDirection wd;
    final wdVal = j['warnDirection'];
    if (wdVal is int) {
      wd = WarnDirection.values[wdVal.clamp(0, WarnDirection.values.length - 1)];
    } else {
      wd = WarnDirection.fromString(wdVal as String? ?? 'high');
    }

    // alertStyle: 兼容旧版无此字段
    AlertStyle as_;
    final asVal = j['alertStyle'] as String?;
    if (asVal != null) {
      as_ = AlertStyle.values.firstWhere((e) => e.name == asVal, orElse: () => AlertStyle.none);
    } else {
      as_ = AlertStyle.none;
    }

    return ChannelConfig(
      label: j['label'] as String? ?? 'DATA',
      jpLabel: j['jpLabel'] as String? ?? '',
      pidId: j['pidId'] as String,
      cautionHigh: (j['cautionHigh'] as num?)?.toDouble() ?? 0,
      dangerHigh: (j['dangerHigh'] as num?)?.toDouble() ?? 0,
      cautionLow: (j['cautionLow'] as num?)?.toDouble() ?? 0,
      dangerLow: (j['dangerLow'] as num?)?.toDouble() ?? 0,
      gaugeMax: (j['gaugeMax'] as num?)?.toDouble() ?? 100,
      warnDirection: wd,
      unitOverride: j['unitOverride'] as String? ?? '',
      alertStyle: as_,
      alertSfxId: j['alertSfxId'] as String? ?? 'none',
      alertTitleJp: j['alertTitleJp'] as String? ?? '',
      alertTitleEn: j['alertTitleEn'] as String? ?? '',
      alertBoostBrightness: j['alertBoostBrightness'] as bool? ?? false,
      alertGuardPidId: j['alertGuardPidId'] as String?,
      alertGuardMinValue: (j['alertGuardMinValue'] as num?)?.toDouble() ?? 0,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 默认通道预设 — ★ 包含警报配置
// ════════════════════════════════════════════════════════════════

const _defaultUdsChannels = [
  ChannelConfig(label: 'BOOST', jpLabel: '増圧B1',  pidId: 'uds_boost_b1',
    cautionHigh: 32, dangerHigh: 38, gaugeMax: 44,
    alertStyle: AlertStyle.overboost, alertSfxId: 'eva_overboost',
    alertTitleJp: '増圧限界', alertTitleEn: 'OVERBOOST'),
  ChannelConfig(label: 'TORQ',  jpLabel: 'トルク',   pidId: 'uds_torque',
    gaugeMax: 900),
  ChannelConfig(label: 'wCOOL', jpLabel: '冷却水',   pidId: 'uds_coolant',
    cautionHigh: 100, dangerHigh: 105, gaugeMax: 140,
    alertStyle: AlertStyle.overheat, alertSfxId: 'eva_cooling',
    alertTitleJp: '冷却過熱', alertTitleEn: 'OVERHEAT',
    alertBoostBrightness: true),
  ChannelConfig(label: 'HP ⛽', jpLabel: '高圧燃料', pidId: 'uds_fuel_hp',
    cautionLow: 5, dangerLow: 2, gaugeMax: 25, warnDirection: WarnDirection.low,
    alertStyle: AlertStyle.fuelCritical, alertSfxId: 'eva_fuelpressurelow',
    alertTitleJp: '燃圧喪失', alertTitleEn: 'FUEL CRITICAL',
    alertBoostBrightness: true),
  ChannelConfig(label: 'AFR',   jpLabel: '空燃比',   pidId: 'uds_lambda_b1',
    cautionHigh: 16.9, dangerHigh: 18.4, cautionLow: 11.5, dangerLow: 10.6,
    gaugeMax: 22, warnDirection: WarnDirection.both,
    alertStyle: AlertStyle.afrAnomaly, alertSfxId: 'eva_afr',
    alertTitleJp: '空燃比異常', alertTitleEn: 'AFR ANOMALY',
    alertGuardPidId: 'uds_accel', alertGuardMinValue: 50),
  ChannelConfig(label: 'KNOCK', jpLabel: '退点火',   pidId: 'uds_kr_avg',
    cautionHigh: 2.25, dangerHigh: 4.5, gaugeMax: 15,
    alertStyle: AlertStyle.emergency, alertSfxId: 'eva_knock',
    alertTitleJp: '非常事態', alertTitleEn: 'EMERGENCY',
    alertBoostBrightness: true),
];

// ★ OBD-II 默认通道 (艾瑞泽8 2.0T)
const _defaultObd2Channels = [
  ChannelConfig(label: 'MAP',   jpLabel: '吸気圧',   pidId: 'uds_boost_b1',
    cautionHigh: 200, dangerHigh: 250, gaugeMax: 300,
    alertStyle: AlertStyle.overboost, alertSfxId: 'eva_overboost',
    alertTitleJp: '増圧限界', alertTitleEn: 'OVERBOOST'),
  ChannelConfig(label: 'TORQ',  jpLabel: 'トルク',   pidId: 'uds_torque',
    cautionHigh: 350, dangerHigh: 400, gaugeMax: 500,
    alertStyle: AlertStyle.generic, alertSfxId: 'none',
    alertTitleJp: '負荷限界', alertTitleEn: 'TORQUE LIMIT'),
  ChannelConfig(label: 'wCOOL', jpLabel: '冷却水',   pidId: 'uds_coolant',
    cautionHigh: 100, dangerHigh: 110, gaugeMax: 140,
    alertStyle: AlertStyle.overheat, alertSfxId: 'eva_cooling',
    alertTitleJp: '冷却過熱', alertTitleEn: 'OVERHEAT',
    alertBoostBrightness: true),
  ChannelConfig(label: 'THR',   jpLabel: 'ｽﾛｯﾄﾙ',  pidId: 'uds_accel',
    cautionHigh: 85, dangerHigh: 95, gaugeMax: 100,
    alertStyle: AlertStyle.generic, alertSfxId: 'none',
    alertTitleJp: '全開', alertTitleEn: 'FULL THROTTLE'),
  ChannelConfig(label: 'IGN',   jpLabel: '点火時期', pidId: 'uds_ign_b1',
    cautionHigh: 35, dangerHigh: 40, cautionLow: -5, dangerLow: -15,
    gaugeMax: 50, warnDirection: WarnDirection.both,
    alertStyle: AlertStyle.generic, alertSfxId: 'none',
    alertTitleJp: '点火異常', alertTitleEn: 'TIMING'),
  ChannelConfig(label: 'RPM',   jpLabel: '回転数',   pidId: 'uds_rpm',
    cautionHigh: 6500, dangerHigh: 7000, gaugeMax: 8000,
    alertStyle: AlertStyle.emergency, alertSfxId: 'eva_knock',
    alertTitleJp: '回転限界', alertTitleEn: 'REDLINE',
    alertBoostBrightness: true),
];

// ════════════════════════════════════════════════════════════════
// 全局通道存储
// ════════════════════════════════════════════════════════════════

const _kStore = 'eva_hud_channels_v8';  // ★ v8: BOOST→psi, Lambda→AFR(*14.7)
const _kStoreMode = 'eva_hud_channels_mode';

class HudChannelStore {
  HudChannelStore._();

  static Map<HudSlot, ChannelConfig> _channels = {};
  static CommMode _channelMode = CommMode.uds;

  static Map<HudSlot, ChannelConfig> get channels => Map.unmodifiable(_channels);

  static ChannelConfig get(HudSlot slot) => _channels[slot] ?? _fallback(slot);

  static Future<void> set(HudSlot slot, ChannelConfig config) async {
    _channels[slot] = config;
    await _save();
  }

  static Future<void> resetDefaults({CommMode? mode}) async {
    final m = mode ?? _channelMode;
    _channels = _buildDefaults(m);
    _channelMode = m;
    await _save();
  }

  static Future<void> switchMode(CommMode mode) async {
    if (_channelMode == mode) return;
    _channelMode = mode;
    _channels = _buildDefaults(mode);
    await _save();
  }

  static Map<HudSlot, ChannelConfig> _buildDefaults(CommMode mode) {
    final defaults = mode == CommMode.obd2 ? _defaultObd2Channels : _defaultUdsChannels;
    final fallbackPid = mode == CommMode.obd2 ? 'uds_rpm' : 'uds_rpm';
    final map = <HudSlot, ChannelConfig>{};
    for (int i = 0; i < HudSlot.values.length; i++) {
      final slot = HudSlot.values[i];
      map[slot] = i < defaults.length
          ? defaults[i]
          : ChannelConfig(label: 'CH${i + 1}', pidId: fallbackPid, gaugeMax: 100);
    }
    return map;
  }

  static ChannelConfig _fallback(HudSlot slot) => ChannelConfig(
    label: 'CH${slot.index + 1}', pidId: 'uds_rpm', gaugeMax: 100);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeIdx = prefs.getInt(_kStoreMode) ?? 0;
      _channelMode = CommMode.values[modeIdx.clamp(0, CommMode.values.length - 1)];
      // 先尝试 v8, 再尝试 v7, v6, v5, v4 兼容
      var json = prefs.getString(_kStore);
      json ??= prefs.getString('eva_hud_channels_v7');
      json ??= prefs.getString('eva_hud_channels_v6');
      json ??= prefs.getString('eva_hud_channels_v5');
      json ??= prefs.getString('eva_hud_channels_v4');
      if (json != null) {
        final map = jsonDecode(json) as Map<String, dynamic>;
        for (final slot in HudSlot.values) {
          if (map.containsKey(slot.name)) {
            _channels[slot] = ChannelConfig.fromJson(
                map[slot.name] as Map<String, dynamic>);
          }
        }
      }
      if (_channels.isEmpty) _channels = _buildDefaults(_channelMode);
    } catch (_) {
      _channels = _buildDefaults(_channelMode);
    }
    await _loadRpmConfig();
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final slot in HudSlot.values) {
      map[slot.name] = (_channels[slot] ?? _fallback(slot)).toJson();
    }
    await prefs.setString(_kStore, jsonEncode(map));
    await prefs.setInt(_kStoreMode, _channelMode.index);
  }

  /// HUD 需要轮询的 PID ID
  static Set<String> get requiredPidIds {
    final ids = <String>{};
    for (final ch in _channels.values) {
      ids.add(ch.pidId);
      // ★ 守衛 PID 也需要轮询
      if (ch.alertGuardPidId != null) ids.add(ch.alertGuardPidId!);
    }
    // ★ 基幹監視 PID — 独立警報 (shift/fullthrottle) + HUD 基本表示
    // 无论用户通道如何配置都必须轮询
    ids.addAll(corePidIds);
    return ids;
  }

  // 基幹監視 — UDS 模式 (档位由用户选择, 不再硬编码)
  static const _kCoreUdsBase = [
    'uds_rpm', 'uds_speed',
    'uds_accel',                            // ★ fullthrottle 依赖
  ];

  // ── 档位 DID 选择 (多 TCU 版本兼容) ──
  static String _selectedGearPidId = 'uds_gear_722';

  static String get selectedGearPidId => _selectedGearPidId;

  static Future<void> setSelectedGearPid(String pidId) async {
    _selectedGearPidId = pidId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('eva_selected_gear_pid', pidId);
  }

  /// 基幹監視 PID 列表 (用于 home_screen 显示)
  /// ★ 档位 PID 仅在 obdPid 模式时加入轮询
  static List<String> get corePidIds => [
    ..._kCoreUdsBase,
    if (_gearSource == GearSource.obdPid) _selectedGearPidId,
  ];

  static List<String> selectablePidIds([CommMode? mode]) =>
      ObdPids.selectableFor(mode ?? _channelMode).map((p) => p.id).toList();

  static String paramName(String pidId) =>
      ObdPids.byId(pidId)?.name ?? pidId;

  static String paramShortName(String pidId) =>
      ObdPids.byId(pidId)?.shortName ?? pidId;

  // ── RPM 配置 (升档警报独立) ──
  static double _rpmMax = 7000;
  static double _shiftRpm = 6500;
  static double get rpmMax => _rpmMax;
  static double get shiftRpm => _shiftRpm;

  // ── 全力全開配置 (独立于通道) ──
  static double _fullThrottleThreshold = 100;
  static bool _fullThrottleEnabled = true;
  static double get fullThrottleThreshold => _fullThrottleThreshold;
  static bool get fullThrottleEnabled => _fullThrottleEnabled;

  static Future<void> setRpmConfig({double? rpmMax, double? shiftRpm}) async {
    if (rpmMax != null) _rpmMax = rpmMax;
    if (shiftRpm != null) _shiftRpm = shiftRpm;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('eva_hud_rpm_max', _rpmMax);
    await prefs.setDouble('eva_hud_shift_rpm', _shiftRpm);
  }

  static Future<void> setFullThrottleConfig({double? threshold, bool? enabled}) async {
    if (threshold != null) _fullThrottleThreshold = threshold;
    if (enabled != null) _fullThrottleEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('eva_hud_ft_threshold', _fullThrottleThreshold);
    await prefs.setBool('eva_hud_ft_enabled', _fullThrottleEnabled);
  }

  static Future<void> _loadRpmConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _rpmMax = prefs.getDouble('eva_hud_rpm_max') ?? 7000;
    _shiftRpm = prefs.getDouble('eva_hud_shift_rpm') ?? 6500;
    _fullThrottleThreshold = prefs.getDouble('eva_hud_ft_threshold') ?? 100;
    _fullThrottleEnabled = prefs.getBool('eva_hud_ft_enabled') ?? true;
    await _loadGearConfig();
  }

  // ── 档位计算器配置 ──
  static List<double> _gearRatios = [4.380, 2.860, 1.920, 1.370, 1.000, 0.820, 0.730];
  static double _finalDrive = 2.820;
  static int _tireWidth = 285;
  static int _tireAspect = 30;
  static int _tireRim = 19;
  static GearSource _gearSource = GearSource.calculated;

  static List<double> get gearRatios => List.unmodifiable(_gearRatios);
  static double get finalDrive => _finalDrive;
  static int get tireWidth => _tireWidth;
  static int get tireAspect => _tireAspect;
  static int get tireRim => _tireRim;
  static GearSource get gearSource => _gearSource;

  /// 轮胎直径 (mm)
  static double get tireDiameterMm =>
      (_tireWidth * _tireAspect / 100) * 2 + _tireRim * 25.4;

  /// 根据 RPM 和车速计算当前档位 (0 = 无法判定)
  static int calcGear(double rpm, double speedKmh) {
    if (rpm < 300 || speedKmh < 3 || _gearRatios.isEmpty) return 0;
    final dMm = tireDiameterMm;
    if (dMm <= 0) return 0;
    // wheel_rpm = speed * 1e6 / (60 * π * d_mm)
    final wheelRpm = speedKmh * 1e6 / (60 * 3.14159265 * dMm);
    int bestGear = 0;
    double bestErr = double.infinity;
    for (int i = 0; i < _gearRatios.length; i++) {
      final expected = wheelRpm * _gearRatios[i] * _finalDrive;
      final err = (rpm - expected).abs();
      if (err < bestErr) { bestErr = err; bestGear = i + 1; }
    }
    // 如果误差超过 RPM 的 20%, 认为无法判定
    if (bestErr > rpm * 0.20) return 0;
    return bestGear;
  }

  static Future<void> setGearConfig({
    List<double>? gearRatios,
    double? finalDrive,
    int? tireWidth,
    int? tireAspect,
    int? tireRim,
    GearSource? gearSource,
  }) async {
    if (gearRatios != null) _gearRatios = List.of(gearRatios);
    if (finalDrive != null) _finalDrive = finalDrive;
    if (tireWidth != null) _tireWidth = tireWidth;
    if (tireAspect != null) _tireAspect = tireAspect;
    if (tireRim != null) _tireRim = tireRim;
    if (gearSource != null) _gearSource = gearSource;
    await _saveGearConfig();
  }

  static Future<void> _saveGearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('eva_gear_ratios', jsonEncode(_gearRatios));
    await prefs.setDouble('eva_gear_final_drive', _finalDrive);
    await prefs.setInt('eva_gear_tire_w', _tireWidth);
    await prefs.setInt('eva_gear_tire_a', _tireAspect);
    await prefs.setInt('eva_gear_tire_r', _tireRim);
    await prefs.setString('eva_gear_source', _gearSource.name);
  }

  static Future<void> _loadGearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    // ★ profile 提供默认值, SharedPreferences 覆盖 (用户自定义优先)
    final p = ProfileManager.instance.active;
    _finalDrive = prefs.getDouble('eva_gear_final_drive') ?? p?.defaultFinalDrive ?? 3.267;
    _tireWidth = prefs.getInt('eva_gear_tire_w') ?? p?.defaultTireWidth ?? 255;
    _tireAspect = prefs.getInt('eva_gear_tire_a') ?? p?.defaultTireAspect ?? 35;
    _tireRim = prefs.getInt('eva_gear_tire_r') ?? p?.defaultTireRim ?? 19;
    final srcName = prefs.getString('eva_gear_source');
    _gearSource = GearSource.values.firstWhere(
        (e) => e.name == srcName, orElse: () => GearSource.calculated);
    final ratioJson = prefs.getString('eva_gear_ratios');
    if (ratioJson != null) {
      try {
        _gearRatios = (jsonDecode(ratioJson) as List).cast<num>().map((e) => e.toDouble()).toList();
      } catch (_) {}
    } else if (p != null && p.defaultGearRatios.isNotEmpty) {
      _gearRatios = List.of(p.defaultGearRatios);
    }
    // ★ 恢复档位 DID 选择 (含旧版 'uds_gear' 迁移)
    var savedGearPid = prefs.getString('eva_selected_gear_pid');
    if (savedGearPid == 'uds_gear') savedGearPid = 'uds_gear_722'; // 旧版迁移
    if (savedGearPid != null && ObdPids.byId(savedGearPid) != null) {
      _selectedGearPidId = savedGearPid;
    } else {
      final gears = ObdPids.gearPids;
      _selectedGearPidId = gears.isNotEmpty ? gears.first.id : 'uds_gear_722';
    }
  }

  /// ★ 车型切换时: 用 profile 默认值重置齿轮比/轮胎参数
  /// 仅当用户未自定义过时才应用 (SharedPreferences 有值 = 用户自定义, 保留)
  static Future<void> applyProfileDefaults({bool force = false}) async {
    final p = ProfileManager.instance.active;
    if (p == null) return;

    if (force) {
      // 强制应用: 清除用户自定义, 完全使用 profile
      _gearRatios = List.of(p.defaultGearRatios);
      _finalDrive = p.defaultFinalDrive;
      _tireWidth = p.defaultTireWidth;
      _tireAspect = p.defaultTireAspect;
      _tireRim = p.defaultTireRim;

      final prefs = await SharedPreferences.getInstance();
      // 清除以让下次 _loadGearConfig 重新读 profile
      await prefs.remove('eva_gear_ratios');
      await prefs.remove('eva_gear_final_drive');
      await prefs.remove('eva_gear_tire_w');
      await prefs.remove('eva_gear_tire_a');
      await prefs.remove('eva_gear_tire_r');
      // 重新选择合适的档位 DID
      final gears = ObdPids.gearPids;
      _selectedGearPidId = gears.isNotEmpty ? gears.first.id : 'uds_gear_722';
      await prefs.setString('eva_selected_gear_pid', _selectedGearPidId);
    }
  }
}