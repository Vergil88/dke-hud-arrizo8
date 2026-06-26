// ════════════════════════════════════════════════════════════════
// vehicle_profile.dart — 车型配置文件 (INI) 解析器 + 数据模型
// ════════════════════════════════════════════════════════════════
// 将原先硬编码的所有通讯参数外部化为 INI 配置文件,
// 使 EVA HUD 可支持任意 UDS 车型.
// ════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'obd_pids.dart';
import 'hud_channel_config.dart';
import '../services/bt_manager.dart';
import '../services/dke_logger.dart';

// ════════════════════════════════════════════════════════════════
// VehicleProfile — 单一车型的全部通讯参数
// ════════════════════════════════════════════════════════════════

class VehicleProfile {
  // ── 车辆信息 ──
  final String name;
  final String platform;
  final String engine;
  final String transmission;
  final String protocol;
  final int yearFrom;
  final int yearTo;
  final String vinPattern;     // ★ VIN 前缀匹配 (空=匹配所有, 如 "LVVDC24B")

  // ── CAN 总线配置 ──
  final int stpProtocol;       // STN 协议号 (33=ISO15765 11-bit 500k)
  final int elmProtocol;       // ELM327 协议号 (6=ISO15765 11-bit 500k)
  final int idBits;            // CAN ID 位数: 11 或 29
  final int bitrate;           // 波特率 (参考)

  // ── ECU 地址表 ──
  final List<EcuAddress> ecuList;

  // ── 超时与时序 ──
  final int stpto;             // STPTO — ECU 响应超时 (ms)
  final int stctorFc;          // STCTOR FC 超时 (ms)
  final int stctorCf;          // STCTOR CF 超时 (ms)
  final int stptrq;            // STPTRQ — 请求间延迟 (ms)
  final String elmTimeout;     // ELM327 ATST 值 (hex string, 如 '32')
  final int stpxCmdTimeout;    // STPX 批量单条超时 (ms)
  final int dynDidReadTimeout; // readDynamicDid STPX T 参数 (ms)

  // ── 流控参数 ──
  final String fcData;         // ATFCSD 数据 (hex, 如 '300000')
  final int fcMode;            // ATFCSM 模式

  // ── 诊断会话 ──
  final String sessionPreferred; // 首选会话 (hex, 如 '03')
  final String sessionFallback;  // 降级会话 (hex, 如 '02')
  final int heartbeatInterval;   // 心跳间隔 (ms)
  final String heartbeatCmd;     // 心跳命令 (hex, 如 '3E80')

  // ── 动态 DID ──
  final int dynamicDidTarget;    // 虚拟 DID 地址 (如 0xF300)
  final bool dynamicDidEnabled;

  // ── DID 定义表 ──
  final List<ObdPid> dids;

  // ── 档位映射列表 ──
  final List<ProfileGearMapping> gearMappings;

  // ── 齿轮比默认值 ──
  final List<double> defaultGearRatios;
  final double defaultFinalDrive;
  final int defaultTireWidth;
  final int defaultTireAspect;
  final int defaultTireRim;

  // ── HUD 默认通道 ──
  final List<ProfileHudSlot> hudDefaults;

  // ── RPM 配置 ──
  final double rpmMax;
  final double shiftRpm;
  final double fullThrottleThreshold;

  // ── 慢变化参数 ──
  final Set<String> slowChangePids;
  final int slowChangeInterval;

  // ── 诊断测试 ──
  final List<String> diagCyclePids;
  final List<String> diagCorePids;
  final List<String> dynDidCandidates;

  const VehicleProfile({
    required this.name,
    this.platform = '',
    this.engine = '',
    this.transmission = '',
    this.protocol = 'UDS',
    this.yearFrom = 0,
    this.yearTo = 9999,
    this.vinPattern = '',       // ★ 空=匹配所有车辆 (通用配置)
    this.stpProtocol = 33,
    this.elmProtocol = 6,
    this.idBits = 11,
    this.bitrate = 500000,
    required this.ecuList,
    this.stpto = 50,
    this.stctorFc = 50,
    this.stctorCf = 100,
    this.stptrq = 0,
    this.elmTimeout = '32',
    this.stpxCmdTimeout = 150,
    this.dynDidReadTimeout = 50,
    this.fcData = '300000',
    this.fcMode = 1,
    this.sessionPreferred = '03',
    this.sessionFallback = '02',
    this.heartbeatInterval = 2000,
    this.heartbeatCmd = '3E80',
    this.dynamicDidTarget = 0xF300,
    this.dynamicDidEnabled = true,
    required this.dids,
    this.gearMappings = const [],
    this.defaultGearRatios = const [4.380, 2.860, 1.920, 1.370, 1.000, 0.820, 0.730],
    this.defaultFinalDrive = 2.820,
    this.defaultTireWidth = 285,
    this.defaultTireAspect = 30,
    this.defaultTireRim = 19,
    this.hudDefaults = const [],
    this.rpmMax = 7000,
    this.shiftRpm = 6500,
    this.fullThrottleThreshold = 100,
    this.slowChangePids = const {},
    this.slowChangeInterval = 3,
    this.diagCyclePids = const [],
    this.diagCorePids = const [],
    this.dynDidCandidates = const [],
  });

  /// 动态 DID 目标地址的高低字节
  String get dynamicDidTargetHex =>
      dynamicDidTarget.toRadixString(16).padLeft(4, '0').toUpperCase();
}

// ════════════════════════════════════════════════════════════════
// 辅助数据类
// ════════════════════════════════════════════════════════════════

class EcuAddress {
  final String tx;
  final String rx;
  final String description;
  const EcuAddress(this.tx, this.rx, this.description);
}

class ProfileGearMapping {
  final String name;
  final String didRef;  // 关联的 DID id
  final int maxForward;
  final Map<int, int> rawToStandard;
  const ProfileGearMapping({
    required this.name,
    required this.didRef,
    required this.maxForward,
    required this.rawToStandard,
  });

  GearMapping toGearMapping() => GearMapping(
    rawToStandard: rawToStandard,
    maxForwardGear: maxForward,
    description: name,
  );
}

class ProfileHudSlot {
  final String pidId;
  final double gaugeMax;
  final double cautionHigh;
  final double dangerHigh;
  final double cautionLow;
  final double dangerLow;
  final String warnDirection;
  final String alertStyle;
  final String alertSfx;
  final String titleJp;
  final String titleEn;
  const ProfileHudSlot({
    required this.pidId,
    required this.gaugeMax,
    this.cautionHigh = 0, this.dangerHigh = 0,
    this.cautionLow = 0, this.dangerLow = 0,
    this.warnDirection = 'high',
    this.alertStyle = 'none',
    this.alertSfx = 'none',
    this.titleJp = '', this.titleEn = '',
  });
}

// ════════════════════════════════════════════════════════════════
// INI 解析器 — 轻量级, 零依赖
// ════════════════════════════════════════════════════════════════

class _IniParser {
  final Map<String, Map<String, String>> sections = {};

  _IniParser.parse(String content) {
    String currentSection = '';
    for (var line in content.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        currentSection = line.substring(1, line.length - 1).trim();
        sections.putIfAbsent(currentSection, () => {});
        continue;
      }
      final eqIdx = line.indexOf('=');
      if (eqIdx < 0) continue;
      final key = line.substring(0, eqIdx).trim();
      final value = line.substring(eqIdx + 1).trim();
      sections.putIfAbsent(currentSection, () => {})[key] = value;
    }
  }

  String? get(String section, String key) => sections[section]?[key];

  int getInt(String section, String key, int fallback) {
    final v = get(section, key);
    if (v == null) return fallback;
    return int.tryParse(v) ?? fallback;
  }

  double getDouble(String section, String key, double fallback) {
    final v = get(section, key);
    if (v == null) return fallback;
    return double.tryParse(v) ?? fallback;
  }

  String getString(String section, String key, String fallback) =>
      get(section, key) ?? fallback;

  bool getBool(String section, String key, bool fallback) {
    final v = get(section, key)?.toLowerCase();
    if (v == null) return fallback;
    return v == 'true' || v == '1' || v == 'yes';
  }

  /// 获取某节中所有 key=value 条目
  Map<String, String> getSection(String section) =>
      sections[section] ?? {};
}

// ════════════════════════════════════════════════════════════════
// VehicleProfile 工厂 — 从 INI 内容构建 VehicleProfile
// ════════════════════════════════════════════════════════════════

class VehicleProfileFactory {
  /// 从 INI 字符串解析
  static VehicleProfile fromIni(String iniContent) {
    final ini = _IniParser.parse(iniContent);

    // ── 车辆信息 ──
    final name = ini.getString('vehicle', 'name', 'Unknown Vehicle');
    final platform = ini.getString('vehicle', 'platform', '');
    final engine = ini.getString('vehicle', 'engine', '');
    final transmission = ini.getString('vehicle', 'transmission', '');
    final protocolStr = ini.getString('vehicle', 'protocol', 'UDS');
    final yearFrom = ini.getInt('vehicle', 'year_from', 0);
    final yearTo = ini.getInt('vehicle', 'year_to', 9999);
    final vinPattern = ini.getString('vehicle', 'vin_pattern', '');  // ★ VIN 匹配

    // ── CAN 总线 ──
    final stpProtocol = ini.getInt('can', 'stp_protocol', 33);
    final elmProtocol = ini.getInt('can', 'elm_protocol', 6);
    final idBits = ini.getInt('can', 'id_bits', 11);
    final bitrate = ini.getInt('can', 'bitrate', 500000);

    // ── ECU 地址表 ──
    final ecuList = <EcuAddress>[];
    final ecuSection = ini.getSection('ecu_list');
    final sortedKeys = ecuSection.keys.toList()..sort();
    for (final key in sortedKeys) {
      final parts = ecuSection[key]!.split(',').map((s) => s.trim()).toList();
      if (parts.length >= 3) {
        ecuList.add(EcuAddress(parts[0], parts[1], parts.sublist(2).join(', ')));
      } else if (parts.length == 2) {
        ecuList.add(EcuAddress(parts[0], parts[1], ''));
      }
    }
    // 兜底: 至少有一个 ECU
    if (ecuList.isEmpty) {
      ecuList.add(const EcuAddress('7E0', '7E8', 'Engine ECU'));
    }

    // ── 超时与时序 ──
    final stpto = ini.getInt('timing', 'stpto', 50);
    final stctorFc = ini.getInt('timing', 'stctor_fc', 50);
    final stctorCf = ini.getInt('timing', 'stctor_cf', 100);
    final stptrq = ini.getInt('timing', 'stptrq', 0);
    final elmTimeout = ini.getString('timing', 'elm_timeout', '32');
    final stpxCmdTimeout = ini.getInt('timing', 'stpx_cmd_timeout', 150);
    final dynDidReadTimeout = ini.getInt('timing', 'dyndid_read_timeout', 50);

    // ── 流控 ──
    final fcData = ini.getString('flow_control', 'fc_data', '300000');
    final fcMode = ini.getInt('flow_control', 'fc_mode', 1);

    // ── 诊断会话 ──
    final sessionPreferred = ini.getString('session', 'preferred', '03');
    final sessionFallback = ini.getString('session', 'fallback', '02');
    final heartbeatInterval = ini.getInt('session', 'heartbeat_interval', 2000);
    final heartbeatCmd = ini.getString('session', 'heartbeat_cmd', '3E80');

    // ── 动态 DID ──
    final dynDidHex = ini.getString('dynamic_did', 'target_did', 'F300');
    final dynamicDidTarget = int.tryParse(dynDidHex, radix: 16) ?? 0xF300;
    final dynamicDidEnabled = ini.getBool('dynamic_did', 'enabled', true);

    // ── DID/PID 定义 ──
    // ★ 检测协议类型以确定字段: UDS→udsDid, OBD-II→obd2Pid
    final isObd2 = protocolStr.toUpperCase() == 'OBD-II' ||
                   protocolStr.toUpperCase() == 'OBD2';
    final dids = <ObdPid>[];
    final didSection = ini.getSection('dids');
    // 同时收集已解析的 gear DID (用于关联 gear_mapping)
    final gearMappingMap = <String, GearMapping>{};

    for (final entry in didSection.entries) {
      final pid = _parseDid(entry.key, entry.value, isObd2: isObd2);
      if (pid != null) dids.add(pid);
    }

    // ── 档位映射 ──
    final gearMappings = <ProfileGearMapping>[];
    for (final secName in ini.sections.keys) {
      if (!secName.startsWith('gear_mapping_')) continue;
      final sec = ini.getSection(secName);
      final gName = sec['name'] ?? secName;
      final gDidRef = sec['did_ref'] ?? '';
      final gMaxFwd = int.tryParse(sec['max_forward'] ?? '7') ?? 7;
      final map = <int, int>{};
      for (final e in sec.entries) {
        if (e.key == 'name' || e.key == 'did_ref' || e.key == 'did' ||
            e.key == 'parse_mode' || e.key == 'max_forward') {
          continue;
        }
        final rawKey = int.tryParse(e.key);
        final rawVal = int.tryParse(e.value);
        if (rawKey != null && rawVal != null) map[rawKey] = rawVal;
      }
      final pgm = ProfileGearMapping(
        name: gName, didRef: gDidRef, maxForward: gMaxFwd, rawToStandard: map,
      );
      gearMappings.add(pgm);
      gearMappingMap[gDidRef] = pgm.toGearMapping();
    }

    // ★ 将档位映射注入对应的 DID (通过 didRef 关联)
    for (int i = 0; i < dids.length; i++) {
      final gm = gearMappingMap[dids[i].id];
      if (gm != null) {
        dids[i] = ObdPid(
          id: dids[i].id, name: dids[i].name, shortName: dids[i].shortName,
          udsDid: dids[i].udsDid, udsEcuTx: dids[i].udsEcuTx, udsEcuRx: dids[i].udsEcuRx,
          parseMode: dids[i].parseMode, byteOffset: dids[i].byteOffset,
          scale: dids[i].scale, offset: dids[i].offset,
          unit: dids[i].unit, group: dids[i].group,
          decimals: dids[i].decimals, gaugeMax: dids[i].gaugeMax,
          normalMax: dids[i].normalMax, gearMapping: gm,
        );
      }
    }

    // ── 齿轮比 ──
    final gearRatios = <double>[];
    final grSection = ini.getSection('gear_ratios');
    for (int i = 1; i <= 10; i++) {
      final v = grSection['gear_$i'];
      if (v == null) break;
      final d = double.tryParse(v);
      if (d != null) gearRatios.add(d);
    }
    final finalDrive = ini.getDouble('gear_ratios', 'final_drive', 2.820);

    // ── 轮胎 ──
    final tireW = ini.getInt('tire', 'width', 285);
    final tireA = ini.getInt('tire', 'aspect', 30);
    final tireR = ini.getInt('tire', 'rim', 19);

    // ── HUD 默认通道 ──
    final hudDefaults = <ProfileHudSlot>[];
    final hudSec = ini.getSection('hud_defaults');
    for (int i = 0; i <= 5; i++) {
      final raw = hudSec['slot_$i'];
      if (raw == null) continue;
      final slot = _parseHudSlot(raw);
      if (slot != null) hudDefaults.add(slot);
    }

    // ── RPM ──
    final rpmMax = ini.getDouble('rpm', 'max', 7000);
    final shiftRpm = ini.getDouble('rpm', 'shift', 6500);
    final ftThreshold = ini.getDouble('rpm', 'full_throttle_threshold', 100);

    // ── 慢变化参数 ──
    final slowPidsRaw = ini.getString('slow_change_pids', 'pids', '');
    final slowPids = slowPidsRaw.isEmpty
        ? <String>{}
        : slowPidsRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
    final slowInterval = ini.getInt('slow_change_pids', 'interval', 3);

    // ── 诊断 ──
    final diagCycle = _splitList(ini.getString('diag_test_pids', 'cycle_pids', ''));
    final diagCore = _splitList(ini.getString('diag_test_pids', 'core_pids', ''));
    final dynCandidates = _splitList(ini.getString('diag_test_pids', 'dyndid_candidates', ''));

    return VehicleProfile(
      name: name, platform: platform, engine: engine,
      transmission: transmission, protocol: protocolStr,
      yearFrom: yearFrom, yearTo: yearTo, vinPattern: vinPattern,
      stpProtocol: stpProtocol, elmProtocol: elmProtocol,
      idBits: idBits, bitrate: bitrate,
      ecuList: ecuList,
      stpto: stpto, stctorFc: stctorFc, stctorCf: stctorCf,
      stptrq: stptrq, elmTimeout: elmTimeout,
      stpxCmdTimeout: stpxCmdTimeout, dynDidReadTimeout: dynDidReadTimeout,
      fcData: fcData, fcMode: fcMode,
      sessionPreferred: sessionPreferred, sessionFallback: sessionFallback,
      heartbeatInterval: heartbeatInterval, heartbeatCmd: heartbeatCmd,
      dynamicDidTarget: dynamicDidTarget, dynamicDidEnabled: dynamicDidEnabled,
      dids: dids,
      gearMappings: gearMappings,
      defaultGearRatios: gearRatios.isNotEmpty ? gearRatios : const [4.380, 2.860, 1.920, 1.370, 1.000, 0.820, 0.730],
      defaultFinalDrive: finalDrive,
      defaultTireWidth: tireW, defaultTireAspect: tireA, defaultTireRim: tireR,
      hudDefaults: hudDefaults,
      rpmMax: rpmMax, shiftRpm: shiftRpm,
      fullThrottleThreshold: ftThreshold,
      slowChangePids: slowPids, slowChangeInterval: slowInterval,
      diagCyclePids: diagCycle, diagCorePids: diagCore,
      dynDidCandidates: dynCandidates,
    );
  }

  /// 从文件路径加载
  static Future<VehicleProfile> fromFile(String path) async {
    final content = await File(path).readAsString(encoding: utf8);
    return fromIni(content);
  }

  /// 从 Flutter asset 加载
  static Future<VehicleProfile> fromAsset(String assetPath) async {
    final content = await rootBundle.loadString(assetPath);
    return fromIni(content);
  }

  // ── DID/PID 行解析器 ──
  // 格式: did_or_pid, ecu_tx, ecu_rx, parse, offset, scale, bias, unit, group,
  //        decimals, gauge_max, normal_max, short_name, full_name
  // isObd2=true 时, did_or_pid 填入 obd2Pid 字段; 否则填入 udsDid
  static ObdPid? _parseDid(String id, String raw, {bool isObd2 = false}) {
    final parts = raw.split(',').map((s) => s.trim()).toList();
    if (parts.length < 10) return null;

    final didOrPid = parts[0];
    final ecuTx = parts[1];
    final ecuRx = parts[2];
    final parseStr = parts[3];
    final byteOffset = int.tryParse(parts[4]) ?? 0;
    final scale = double.tryParse(parts[5]) ?? 1.0;
    final offset = double.tryParse(parts[6]) ?? 0.0;
    final unit = parts[7];
    final groupStr = parts[8];
    final decimals = int.tryParse(parts[9]) ?? 1;
    final gaugeMax = parts.length > 10 ? (double.tryParse(parts[10]) ?? 100) : 100.0;
    final normalMax = parts.length > 11 && parts[11].isNotEmpty
        ? double.tryParse(parts[11])
        : null;
    final shortName = parts.length > 12 ? parts[12] : id;
    final name = parts.length > 13 ? parts[13] : shortName;

    final parseMode = switch (parseStr) {
      'u8'  => ParseMode.uint8,
      'u16' => ParseMode.uint16be,
      'i8'  => ParseMode.int8,
      'i16' => ParseMode.int16be,
      'u32' => ParseMode.uint32be,
      _     => ParseMode.uint8,
    };

    final group = switch (groupStr) {
      'engine'  => PidGroup.engine,
      'fuel'    => PidGroup.fuel,
      'boost'   => PidGroup.boost,
      'timing'  => PidGroup.timing,
      'knock'   => PidGroup.knock,
      'air'     => PidGroup.air,
      'lambda'  => PidGroup.lambda,
      'cam'     => PidGroup.cam,
      'gear'    => PidGroup.gear,
      _         => PidGroup.misc,
    };

    // ★ 根据协议类型设置相应字段
    return ObdPid(
      id: id, name: name, shortName: shortName,
      udsDid: isObd2 ? '' : didOrPid,
      obd2Pid: isObd2 ? didOrPid : '',
      obd2Mode: isObd2 ? '01' : '',
      udsEcuTx: ecuTx, udsEcuRx: ecuRx,
      parseMode: parseMode, byteOffset: byteOffset,
      scale: scale, offset: offset,
      unit: unit, group: group,
      decimals: decimals, gaugeMax: gaugeMax,
      normalMax: normalMax,
    );
  }

  static ProfileHudSlot? _parseHudSlot(String raw) {
    final parts = raw.split(',').map((s) => s.trim()).toList();
    if (parts.length < 2) return null;
    return ProfileHudSlot(
      pidId: parts[0],
      gaugeMax: double.tryParse(parts.length > 1 ? parts[1] : '100') ?? 100,
      cautionHigh: double.tryParse(parts.length > 2 ? parts[2] : '0') ?? 0,
      dangerHigh: double.tryParse(parts.length > 3 ? parts[3] : '0') ?? 0,
      cautionLow: double.tryParse(parts.length > 4 ? parts[4] : '0') ?? 0,
      dangerLow: double.tryParse(parts.length > 5 ? parts[5] : '0') ?? 0,
      warnDirection: parts.length > 6 ? parts[6] : 'high',
      alertStyle: parts.length > 7 ? parts[7] : 'none',
      alertSfx: parts.length > 8 ? parts[8] : 'none',
      titleJp: parts.length > 9 ? parts[9] : '',
      titleEn: parts.length > 10 ? parts[10] : '',
    );
  }

  static List<String> _splitList(String raw) =>
      raw.isEmpty ? [] : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

// ════════════════════════════════════════════════════════════════
// ProfileManager — 全局配置管理器 (单例)
// ════════════════════════════════════════════════════════════════
//
// ★ 职责:
//   - 管理当前激活的 VehicleProfile
//   - 持久化用户选择 (SharedPreferences)
//   - 提供内置配置列表 + 自定义 INI 导入
//   - 通知 BtManager / ObdPids / HudChannelStore 切换配置

class ProfileManager {
  static final ProfileManager instance = ProfileManager._();
  ProfileManager._();

  VehicleProfile? _active;

  /// 当前激活的车型配置 (未加载时为 null, 使用内置 C63s 默认)
  VehicleProfile? get active => _active;

  /// 是否已加载配置
  bool get hasProfile => _active != null;

  /// 当前配置名称 (未加载时返回内置默认名)
  String get activeName => _active?.name ?? 'Mercedes-AMG C63s (W205) [内置]';

  /// VIN 匹配成功标志 (连接后设置)
  bool vinMatched = false;

  // ── 内置配置 ID ──
  static const _kPrefKey = 'eva_active_profile';
  static const _kCustomIniPrefix = 'eva_custom_ini_';
  static const builtinId = '__builtin_c63s__';

  // ★ 多内置配置注册表 (C63s 为 null → 硬编码默认)
  static const _builtinProfiles = <String, String>{
    '__builtin_arrizo8_uds__':  'assets/profiles/arrizo8_uds.ini',
    '__builtin_arrizo8_obd2__': 'assets/profiles/arrizo8_20t.ini',
    '__builtin_generic_obd2__': 'assets/profiles/generic_obd2.ini',
  };

  /// 获取所有内置配置 ID 列表
  List<String> get builtinProfileIds => ['__builtin_c63s__', ..._builtinProfiles.keys];

  /// 当前激活的配置 ID (用于UI判断)
  Future<String> getActiveId() async {
    if (_active == null) return '__builtin_c63s__';
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPrefKey) ?? '__builtin_c63s__';
  }

  /// 初始化: 从持久化恢复上次选择
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_kPrefKey);
    if (savedId != null && savedId != builtinId) {
      // 尝试加载自定义 INI
      final iniContent = prefs.getString('$_kCustomIniPrefix$savedId');
      if (iniContent != null) {
        try {
          _active = VehicleProfileFactory.fromIni(iniContent);
          DkeLogger.instance.write('PRF', '恢复自定义配置: ${_active!.name} ($savedId)');
          _applyProfile();
          return;
        } catch (e) {
          DkeLogger.instance.write('PRF', '自定义配置解析失败, 回退内置');
        }
      }
      // 尝试加载内置配置 (非 C63s)
      if (_builtinProfiles.containsKey(savedId)) {
        try {
          _active = await VehicleProfileFactory.fromAsset(_builtinProfiles[savedId]!);
          DkeLogger.instance.write('PRF', '恢复内置配置: ${_active!.name} ($savedId)');
          _applyProfile();
          return;
        } catch (e) {
          DkeLogger.instance.write('PRF', '内置配置加载失败: $savedId');
        }
      }
    }
    // null = 使用内置 C63s 硬编码 (向后兼容)
    _active = null;
  }

  /// 切换到内置配置 (清除自定义)
  Future<void> useBuiltin([String id = builtinId]) async {
    if (id == builtinId || !_builtinProfiles.containsKey(id)) {
      _active = null;
    } else {
      try {
        _active = await VehicleProfileFactory.fromAsset(_builtinProfiles[id]!);
      } catch (e) {
        DkeLogger.instance.write('PRF', '内置配置加载失败: $id');
        _active = null;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefKey, id);
    _applyProfile();
  }

  /// 从 INI 字符串导入自定义配置
  Future<void> importIni(String iniContent, {String? profileId}) async {
    final profile = VehicleProfileFactory.fromIni(iniContent);
    _active = profile;

    final id = profileId ?? profile.name.hashCode.toRadixString(16);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefKey, id);
    await prefs.setString('$_kCustomIniPrefix$id', iniContent);
    _applyProfile();
  }

  /// 从文件路径导入
  Future<void> importFromFile(String path) async {
    DkeLogger.instance.write('PRF', '加载 INI: $path');
    final content = await File(path).readAsString(encoding: utf8);
    await importIni(content);
  }

  /// ★ VIN 自动匹配: 连接后调用, 尝试匹配最佳配置
  /// 返回 true 表示已自动切换配置
  Future<bool> autoMatchVin(String vin) async {
    if (vin.isEmpty) return false;

    // 1. 先检查当前激活配置是否已匹配
    if (_active != null && _active!.vinPattern.isNotEmpty) {
      if (vin.startsWith(_active!.vinPattern)) {
        vinMatched = true;
        DkeLogger.instance.write('PRF', '✅ VIN 匹配当前配置: ${_active!.name} (${_active!.vinPattern})');
        return false; // 无需切换
      }
    }

    // 2. 扫描内置配置 (非 C63s) 寻找匹配
    for (final entry in _builtinProfiles.entries) {
      if (entry.key == builtinId) continue;
      try {
        final profile = await VehicleProfileFactory.fromAsset(entry.value);
        if (profile.vinPattern.isNotEmpty && vin.startsWith(profile.vinPattern)) {
          _active = profile;
          vinMatched = true;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kPrefKey, entry.key);
          _applyProfile();
          DkeLogger.instance.write('PRF', '✅ VIN 自动匹配 → ${profile.name} (${profile.vinPattern})');
          return true;
        }
      } catch (_) {}
    }

    // 3. 无匹配 — 如果当前配置有 VIN 限制, 警告并切换到通用
    if (_active != null && _active!.vinPattern.isNotEmpty) {
      DkeLogger.instance.write('PRF', '⚠ VIN 不匹配! 当前:${_active!.vinPattern} 实际:${vin.substring(0, _active!.vinPattern.length.clamp(0, 8))}...');
      // 自动切换到适用的通用配置
      final isCurrentlyObd2 = _active!.protocol.toUpperCase() == 'OBD-II' ||
                               _active!.protocol.toUpperCase() == 'OBD2';
      if (isCurrentlyObd2) {
        try {
          _active = await VehicleProfileFactory.fromAsset(_builtinProfiles['__builtin_generic_obd2__']!);
          vinMatched = false;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kPrefKey, '__builtin_generic_obd2__');
          _applyProfile();
          DkeLogger.instance.write('PRF', '⚠ 已切换到通用 OBD-II 配置 (VIN不匹配)');
          return true;
        } catch (_) {}
      }
    } else {
      DkeLogger.instance.write('PRF', 'VIN: $vin (无匹配配置, 保持当前)');
    }

    vinMatched = _active == null || _active!.vinPattern.isEmpty;
    return false;
  }

  /// 应用当前配置到各子系统
  void _applyProfile() {
    try {
      if (_active != null) {
        final p = _active!;
        ObdPids.loadFromProfile(p);
        final isObd2 = p.protocol.toUpperCase() == 'OBD-II' ||
                       p.protocol.toUpperCase() == 'OBD2';
        final targetMode = isObd2 ? CommMode.obd2 : CommMode.uds;
        BtManager.instance.commMode = targetMode;
        HudChannelStore.switchMode(targetMode);

        DkeLogger.instance.write('PRF', '══════════════════════════════');
        DkeLogger.instance.write('PRF', 'Profile: ${p.name}');
        DkeLogger.instance.write('PRF', '  协议: ${p.protocol} → ${targetMode.name}');
        DkeLogger.instance.write('PRF', '  VIN匹配: ${p.vinPattern.isNotEmpty ? p.vinPattern : "通用(无限制)"}');
        DkeLogger.instance.write('PRF', '  ECU: ${p.ecuList.map((e) => "${e.tx}/${e.rx}").join(", ")}');
        DkeLogger.instance.write('PRF', '  DID/PID 总数: ${p.dids.length}');
        DkeLogger.instance.write('PRF', '  齿比: ${p.defaultGearRatios.map((g) => g.toStringAsFixed(3)).join(", ")}');
        DkeLogger.instance.write('PRF', '  终传比: ${p.defaultFinalDrive}');
        DkeLogger.instance.write('PRF', '══════════════════════════════');
      } else {
        ObdPids.resetToBuiltin();
        HudChannelStore.resetDefaults(mode: CommMode.uds);
        DkeLogger.instance.write('PRF', 'Profile: 内置 C63s (UDS)');
      }
    } catch (e, st) {
      DkeLogger.instance.write('ERR', '_applyProfile 异常: $e');
      DkeLogger.instance.write('ERR', '  $st');
    }
  }

  /// 获取已保存的自定义配置列表
  Future<List<String>> getSavedProfileIds() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    return keys
        .where((k) => k.startsWith(_kCustomIniPrefix))
        .map((k) => k.substring(_kCustomIniPrefix.length))
        .toList();
  }

  /// 删除已保存的自定义配置
  Future<void> deleteProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_kCustomIniPrefix$profileId');
    if (prefs.getString(_kPrefKey) == profileId) {
      await useBuiltin();
    }
  }
}
